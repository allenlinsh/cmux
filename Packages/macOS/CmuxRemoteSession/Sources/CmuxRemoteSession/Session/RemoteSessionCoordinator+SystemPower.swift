internal import Foundation

extension RemoteSessionCoordinator {
    /// Pauses reconnect-policy accounting while the local Mac is asleep.
    public func prepareForSystemSleep() {
        queue.async { [weak self] in
            self?.prepareForSystemSleepLocked()
        }
    }

    /// Clears any terminal reconnect suspension after an external re-arm signal.
    ///
    /// A reconnect is scheduled when the coordinator was suspended or no longer
    /// has a ready proxy. System wake also forces a transport reset for proxy-
    /// backed SSH sessions: long sleep often leaves a still-marked-ready proxy
    /// whose TCP path is already dead (common with Tailscale after lid open).
    /// Network-path re-arms keep the healthy-proxy skip so flapping interfaces
    /// do not tear down live sessions.
    ///
    /// - Parameter reason: A diagnostic label for the re-arm signal.
    public func resetReconnectPolicyAndReconnect(reason: String) {
        queue.async { [weak self] in
            guard let self else { return }
            let shouldReconnect = self.resetReconnectPolicyLocked(reason: reason)
            guard shouldReconnect else { return }
            self.resetTransportForReconnectLocked()
            _ = self.scheduleReconnectLocked(baseDelay: 2.0)
        }
    }

    func prepareForSystemSleepLocked() {
        guard !isStopping else { return }
        isSystemSleeping = true
        cancelReconnectRetryLocked()
        cancelSuspendedReachabilityProbeLocked()
        reachabilityProbeGeneration &+= 1
        debugLog("remote.session.systemSleep \(debugConfigSummary())")
    }

    @discardableResult
    func resetReconnectPolicyLocked(reason: String) -> Bool {
        guard !isStopping else { return false }
        let expectsProxyEndpoint = !configuration.skipDaemonBootstrap ||
            configuration.daemonWebSocketEndpoint != nil
        // Long sleep commonly freezes a still-ready proxy whose TCP path is
        // already dead; wake must rebuild it instead of waiting for a late error.
        let forceReconnectAfterSystemWake = expectsProxyEndpoint &&
            reason == "system wake"
        let shouldReconnect = forceReconnectAfterSystemWake ||
            reconnectSuspended ||
            reconnectRetryCount > 0 ||
            (expectsProxyEndpoint && proxyEndpoint == nil) ||
            !daemonReady
        isSystemSleeping = false
        cancelReconnectRetryLocked()
        cancelSuspendedReachabilityProbeLocked()
        reconnectRetryCount = 0
        consecutiveUnreachableProbeCount = 0
        resetBootstrapFailureTrackingLocked()
        reconnectSuspended = false
        reachabilityProbeGeneration &+= 1
        reconnectSuspendGraceUntil = reconnectNow().addingTimeInterval(
            Self.postRearmSuspendGraceSeconds
        )
        debugLog(
            "remote.session.reconnect.rearmed reason=\(reason.debugLogSnippet(limit: 80)) " +
                "reconnect=\(shouldReconnect ? 1 : 0) \(debugConfigSummary())"
        )
        return shouldReconnect
    }

    func resetTransportForReconnectLocked(
        preservePersistentRelayMetadata: Bool = false
    ) {
        cancelTransportDependentWorkLocked()
        cancelReverseRelayRestartLocked()
        if preservePersistentRelayMetadata {
            invalidateReverseRelayAfterControlMasterReapLocked()
        } else {
            stopReverseRelayLocked()
        }
        // Wait-for-ready bridge requests belong to the persistent remote PTY,
        // not to this particular local transport lease. Leave them parked so
        // a sleep/wake or transient reconnect does not manufacture a failed
        // attach that the pane immediately has to retry.
        releaseProxyLeaseLocked()
        proxyEndpoint = nil
        daemonReady = false
        daemonBootstrapVersion = nil
        daemonRemotePath = nil
        publishProxyEndpoint(nil)
    }

    private func cancelTransportDependentWorkLocked() {
        bootstrapRemoteTTYResolved = false
        bootstrapRemoteTTYFetchInFlight = false
        suspendRemotePortScanningLocked()
    }

    func releaseProxyLeaseLocked() {
        proxyLeaseGeneration &+= 1
        proxyLease?.release()
        proxyLease = nil
    }
}
