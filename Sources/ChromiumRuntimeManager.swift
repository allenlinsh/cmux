import AppKit
import CmuxChromium
import Foundation

/// Owns the single per-process OWL Chromium runtime and opens surface sessions.
@MainActor
final class ChromiumRuntimeManager {
    static let shared = ChromiumRuntimeManager()

    // Chromium cannot be unloaded; the runtime lives for the process.
    private var runtime: ChromiumRuntime?

    /// Once-per-run guard for the Chromium→WebKit fallback notification, owned
    /// here (with the runtime lifecycle) rather than as ambient global state.
    private var didNotifyFallback = false

    func isRuntimeAvailable() -> Bool {
        (try? ChromiumRuntimeLocator().locate()) != nil
    }

    /// Posts the "Chromium unavailable — using WebKit" notification at most
    /// once per app run, no matter how many surfaces degrade.
    func postFallbackNotificationIfNeeded(workspaceId: UUID) {
        guard !didNotifyFallback else { return }
        didNotifyFallback = true
        TerminalNotificationStore.shared.addNotification(
            tabId: workspaceId,
            surfaceId: nil,
            title: String(
                localized: "chromium.fallback.title",
                defaultValue: "Chromium unavailable — using WebKit"
            ),
            subtitle: "",
            body: String(
                localized: "chromium.fallback.body",
                defaultValue: "Install a runtime with scripts/fetch-chromium-runtime.sh, then open a new browser surface."
            )
        )
    }

    func acquireSession(
        initialURL: String,
        profileID: UUID,
        proxyServer: String? = nil
    ) async throws -> (ChromiumSession, ChromiumBrowserModel, ChromiumWebView) {
        let runtime: ChromiumRuntime
        if let existing = self.runtime {
            runtime = existing
        } else {
            let bundle = try ChromiumRuntimeLocator().locate()
            runtime = ChromiumRuntime(bundle: bundle)
            self.runtime = runtime
        }
        try await runtime.start()
        let session = try await runtime.openSession(
            initialURL: initialURL,
            userDataDirectory: surfaceDataDirectory(profileID: profileID),
            proxyServer: proxyServer,
            enableDevTools: true
        )
        let model = ChromiumBrowserModel()
        let webView = ChromiumWebView(session: session, model: model)
        return (session, model, webView)
    }

    /// Per-surface directory: one Content Shell process per surface cannot share
    /// a Chromium profile dir (process-level lock), so cookies are per-surface in M1.
    private func surfaceDataDirectory(profileID: UUID) -> URL? {
        guard let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        let dir = base.appendingPathComponent("cmux/chromium-profiles/\(profileID.uuidString)/surface-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
