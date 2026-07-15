import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

// Regression coverage for the Chromium runtime wedge: the 1s URL/title poll
// (and the history/reload JavaScript shims) must not call
// `shell_execute_javascript` before the session's first real committed
// navigation, or while the main frame is mid-navigation.
//
// `owl_fresh_mojo_shell_execute_javascript` blocks the pinned
// `com.cmux.chromium-runtime` thread in a nested RunLoop until the shell's
// main frame returns a result. A Content Shell that is still booting on
// about:blank never replies, so a single poll tick in that window wedges the
// runtime thread — and with it every queued session command (navigate,
// resize, openSession) for every Chromium surface — until the app restarts.
// Observed in the wild as "browser tabs show a blank page and nothing loads
// anymore, for any URL".
@Suite("Chromium session JavaScript safety gate")
struct BrowserPanelChromiumPollSafetyTests {
    @Test func uncommittedSessionIsUnsafe() {
        #expect(!BrowserPanel.chromiumSessionJavaScriptIsSafe(
            committedURLString: "",
            isLoading: false
        ))
    }

    @Test func blankCommittedURLIsUnsafe() {
        #expect(!BrowserPanel.chromiumSessionJavaScriptIsSafe(
            committedURLString: "about:blank",
            isLoading: false
        ))
    }

    @Test func whitespaceCommittedURLIsUnsafe() {
        #expect(!BrowserPanel.chromiumSessionJavaScriptIsSafe(
            committedURLString: "  \n",
            isLoading: false
        ))
    }

    @Test func loadingMainFrameIsUnsafe() {
        #expect(!BrowserPanel.chromiumSessionJavaScriptIsSafe(
            committedURLString: "https://example.com/",
            isLoading: true
        ))
    }

    @Test func committedIdlePageIsSafe() {
        #expect(BrowserPanel.chromiumSessionJavaScriptIsSafe(
            committedURLString: "https://example.com/",
            isLoading: false
        ))
    }
}
