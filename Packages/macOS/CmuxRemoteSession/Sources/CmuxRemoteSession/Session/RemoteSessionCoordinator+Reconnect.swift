internal import Foundation

// Reconnect backoff scheduling and the reachability-based suspend policy
// (https://github.com/manaflow-ai/cmux/issues/5734). Faithful lift; the
// legacy `asyncAfter` work item became an injected-clock task whose wakeup is
// guarded by a token (strictly tighter than the legacy work-item cancel) —
// delays, retry numbering, and suffix strings are identical.
//
// Post-#5734 recovery gaps for sleep / Tailscale:
// - After wake or network re-arm, unreachable probes do not suspend for
//   `postRearmSuspendGraceSeconds` so short settle windows (Wi-Fi, Tailscale)
//   do not strand the workspace on a manual Reconnect.
// - Once suspended, a low-rate reachability probe keeps watching the host and
//   auto re-arms when it becomes reachable again (path monitor alone misses
//   cases where the default path stays "satisfied" while the SSH route is not).
extension RemoteSessionCoordinator {
    /// How long after an external re-arm unreachable probes may not suspend.
    static let postRearmSuspendGraceSeconds: TimeInterval = 90
    /// Interval between reachability probes while auto-reconnect is suspended.
    static let suspendedReachabilityProbeIntervalSeconds: TimeInterval = 15

    @discardableResult
    func scheduleReconnectLocked(baseDelay: TimeInterval) -> RetrySchedule {
        let retryNumber = reconnectRetryCount + 1
        let retryDelay = Self.retryDelay(baseDelay: baseDelay, retry: retryNumber)
        guard !isStopping, !reconnectSuspended, !isSystemSleeping else {
            return RetrySchedule(retry: retryNumber, delay: retryDelay)
        }
        cancelReconnectRetryLocked()
        reconnectRetryCount = retryNumber
        // Whole-second legacy delays convert exactly; round up so the delay
        // can never undershoot the legacy deadline.
        let milliseconds = Int((retryDelay * 1000).rounded(.up))
        let token = UUID()
        reconnectToken = token
        // Cancellation is absorbed by guards, not checks: a cancelled sleep
        // throws (no wakeup), and a stale post-sleep wakeup fails the token
        // guard because every cancel/consume path clears or replaces the
        // token first.
        reconnectTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.clock.sleep(forMilliseconds: milliseconds)) != nil else { return }
            self.queue.async {
                self.reconnectDelayElapsed(token: token)
            }
        }
        evaluateReconnectPolicyLocked()
        return RetrySchedule(retry: retryNumber, delay: retryDelay)
    }

    /// Runs on `queue` after the reconnect backoff; the token guard drops
    /// stale wakeups from consumed, cancelled, or replaced retries.
    private func reconnectDelayElapsed(token: UUID) {
        guard reconnectToken == token else { return }
        reconnectTask = nil
        reconnectToken = nil
        guard !isStopping, !isSystemSleeping else { return }
        guard proxyLease == nil else { return }
        requestConnectionAttemptLocked()
    }

    func cancelReconnectRetryLocked() {
        reconnectTask?.cancel()
        reconnectTask = nil
        reconnectToken = nil
    }

    func cancelSuspendedReachabilityProbeLocked() {
        suspendedReachabilityProbeTask?.cancel()
        suspendedReachabilityProbeTask = nil
        suspendedReachabilityProbeToken = nil
    }

    /// Probe whether the SSH endpoint is reachable at all after a failed
    /// connection attempt. While the host stays unreachable the retry loop is
    /// allowed a short streak of attempts (absorbing sleep/wake and network
    /// handoffs) and then suspends instead of retrying indefinitely
    /// (https://github.com/manaflow-ai/cmux/issues/5734).
    func evaluateReconnectPolicyLocked() {
        guard configuration.transport == .ssh else { return }
        reachabilityProbeGeneration &+= 1
        let generation = reachabilityProbeGeneration
        reachabilityProbe.probe(
            destination: configuration.destination,
            port: configuration.port,
            identityFile: configuration.identityFile,
            sshOptions: configuration.sshOptions
        ) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                self.handleReachabilityProbeOutcomeLocked(outcome, generation: generation)
            }
        }
    }

    func handleReachabilityProbeOutcomeLocked(
        _ outcome: RemoteHostProbeOutcome,
        generation: UInt64
    ) {
        guard generation == reachabilityProbeGeneration else { return }
        guard !isStopping, !reconnectSuspended, !isSystemSleeping else { return }
        // The probe only judges a still-pending retry; if the retry resolved
        // while the probe ran, the connected/stopped paths own the state.
        guard reconnectToken != nil else { return }
        let evaluation = reconnectPolicy.evaluate(
            outcome: outcome,
            previousConsecutiveUnreachableProbes: consecutiveUnreachableProbeCount
        )
        consecutiveUnreachableProbeCount = evaluation.consecutiveUnreachableProbes
        let inSuspendGrace = isWithinReconnectSuspendGraceLocked()
        let shouldSuspend = evaluation.decision == .suspend && !inSuspendGrace
        debugLog(
            "remote.session.reachability outcome=\(Self.debugDescription(for: outcome)) " +
            "streak=\(evaluation.consecutiveUnreachableProbes) " +
            "decision=\(shouldSuspend ? "suspend" : "retry") " +
            "grace=\(inSuspendGrace ? 1 : 0) \(debugConfigSummary())"
        )
        if shouldSuspend {
            suspendAutoReconnectLocked()
        } else if evaluation.decision == .suspend, inSuspendGrace {
            // Keep aggressive backoff alive while network settles after wake/path rearm.
            consecutiveUnreachableProbeCount = max(0, reconnectPolicy.maxConsecutiveUnreachableProbes - 1)
        }
    }

    func isWithinReconnectSuspendGraceLocked() -> Bool {
        guard let reconnectSuspendGraceUntil else { return false }
        return reconnectNow() < reconnectSuspendGraceUntil
    }

    /// Halt the aggressive reconnect loop and surface a suspended state with a
    /// manual Reconnect affordance. A low-rate reachability probe keeps
    /// watching the host and auto re-arms when it becomes reachable again —
    /// needed when Tailscale / sleep recovery takes longer than the active
    /// retry window and NWPathMonitor does not report a further path change.
    ///
    /// `Workspace.reconnectRemoteConnection()` (sidebar button, workspace
    /// context menu, `cmux workspace reconnect`, and the
    /// `workspace.remote.reconnect` socket command) still replaces this
    /// coordinator immediately.
    func suspendAutoReconnectLocked() {
        cancelReconnectRetryLocked()
        reconnectSuspended = true
        debugLog(
            "remote.session.reconnect.suspended afterUnreachableProbes=\(consecutiveUnreachableProbeCount) " +
            debugConfigSummary()
        )
        let detail = String(format: strings.suspendedDetailFormat, configuration.displayTarget)
        publishDaemonStatus(.unavailable, detail: detail)
        publishState(.suspended, detail: detail)
        scheduleSuspendedReachabilityProbeLocked()
    }

    func scheduleSuspendedReachabilityProbeLocked() {
        guard configuration.transport == .ssh else { return }
        cancelSuspendedReachabilityProbeLocked()
        let token = UUID()
        suspendedReachabilityProbeToken = token
        let milliseconds = Int((Self.suspendedReachabilityProbeIntervalSeconds * 1000).rounded(.up))
        suspendedReachabilityProbeTask = Task { [weak self] in
            guard let self else { return }
            guard (try? await self.clock.sleep(forMilliseconds: milliseconds)) != nil else { return }
            self.queue.async {
                self.suspendedReachabilityProbeElapsedLocked(token: token)
            }
        }
    }

    func suspendedReachabilityProbeElapsedLocked(token: UUID) {
        guard suspendedReachabilityProbeToken == token else { return }
        suspendedReachabilityProbeTask = nil
        suspendedReachabilityProbeToken = nil
        guard !isStopping, reconnectSuspended, !isSystemSleeping else { return }
        reachabilityProbeGeneration &+= 1
        let generation = reachabilityProbeGeneration
        reachabilityProbe.probe(
            destination: configuration.destination,
            port: configuration.port,
            identityFile: configuration.identityFile,
            sshOptions: configuration.sshOptions
        ) { [weak self] outcome in
            guard let self else { return }
            self.queue.async {
                self.handleSuspendedReachabilityProbeOutcomeLocked(outcome, generation: generation)
            }
        }
    }

    func handleSuspendedReachabilityProbeOutcomeLocked(
        _ outcome: RemoteHostProbeOutcome,
        generation: UInt64
    ) {
        guard generation == reachabilityProbeGeneration else { return }
        guard !isStopping, reconnectSuspended, !isSystemSleeping else { return }
        debugLog(
            "remote.session.reachability.suspended outcome=\(Self.debugDescription(for: outcome)) " +
            debugConfigSummary()
        )
        switch outcome {
        case .reachable:
            let shouldReconnect = resetReconnectPolicyLocked(reason: "suspended host became reachable")
            guard shouldReconnect else { return }
            resetTransportForReconnectLocked()
            _ = scheduleReconnectLocked(baseDelay: 2.0)
        case .unreachable, .indeterminate:
            scheduleSuspendedReachabilityProbeLocked()
        }
    }

    static func debugDescription(for outcome: RemoteHostProbeOutcome) -> String {
        switch outcome {
        case .reachable:
            return "reachable"
        case .unreachable(let reason):
            return "unreachable(\(reason.debugLogSnippet(limit: 80)))"
        case .indeterminate:
            return "indeterminate"
        }
    }

    static func retrySuffix(retry: Int, delay: TimeInterval) -> String {
        let seconds = max(1, Int(delay.rounded()))
        return " (retry \(retry) in \(seconds)s)"
    }

    static func retryDelay(baseDelay: TimeInterval, retry: Int) -> TimeInterval {
        let exponent = Double(max(0, retry - 1))
        return min(baseDelay * pow(2.0, exponent), 60.0)
    }

    static func shouldEscalateProxyErrorToBootstrap(_ detail: String) -> Bool {
        let lowered = detail.lowercased()
        return lowered.contains("remote daemon transport failed")
            || lowered.contains("daemon transport closed stdout")
            || lowered.contains("daemon transport exited")
            || lowered.contains("daemon transport is not connected")
            || lowered.contains("daemon transport stopped")
    }
}
