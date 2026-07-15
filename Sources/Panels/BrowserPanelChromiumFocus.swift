import AppKit

/// Focus routing for `.chromium` surfaces: the engine's mounted content view
/// takes first responder instead of the panel's (never-mounted) WKWebView.
extension BrowserPanel {
    /// The chromium engine's content view for focus routing. DEBUG builds may
    /// inject `chromiumWebContentViewOverrideForTesting` so focus behavior is
    /// testable without a live Content Shell session.
    var chromiumWebContentView: NSView? {
#if DEBUG
        if let override = chromiumWebContentViewOverrideForTesting {
            return override
        }
#endif
        return chromium?.webView
    }

    func focusChromiumWebView() {
        guard let chromiumView = chromiumWebContentView,
              let window = chromiumView.window,
              !chromiumView.isHiddenOrHasHiddenAncestor else { return }
        if Self.responderChainContains(window.firstResponder, target: chromiumView) {
            noteWebViewFocused()
            return
        }
        if window.makeFirstResponder(chromiumView) {
            noteWebViewFocused()
        }
    }
}
