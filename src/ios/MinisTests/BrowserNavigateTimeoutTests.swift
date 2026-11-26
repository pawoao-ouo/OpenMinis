import XCTest
import UIKit
import WebKit
@testable import Minis

@MainActor
final class BrowserNavigateTimeoutTests: XCTestCase {
    func testFailedNavigationDoesNotRestoreInitialAboutBlankPage() {
        XCTAssertFalse(
            BrowserUseManager.shouldRestorePreviousPage(
                canGoBack: true,
                backItemURL: URL(string: "about:blank")
            )
        )
        XCTAssertFalse(
            BrowserUseManager.shouldRestorePreviousPage(canGoBack: true, backItemURL: nil)
        )
    }

    func testFailedNavigationStillRestoresRealPreviousPage() {
        XCTAssertTrue(
            BrowserUseManager.shouldRestorePreviousPage(
                canGoBack: true,
                backItemURL: URL(string: "https://example.com/")
            )
        )
        XCTAssertFalse(
            BrowserUseManager.shouldRestorePreviousPage(
                canGoBack: false,
                backItemURL: URL(string: "https://example.com/")
            )
        )
    }

    func testWebViewFailureDOMHidesFailedURLAndRetryUsesExactAddress() async throws {
        let schemeHandler = BrowserRecoveryFixtureSchemeHandler()
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "minis-clone")
        let manager = BrowserUseManager(profile: .mobileSafari, customString: nil,
                                        configuration: configuration)
        let failedURL = URL(string: "minis-clone://fixture/retry?token=PRIVATE_MARKER_71a9&two=three")!
        manager.loadURL(failedURL.absoluteString)

        _ = try await waitForDOM(in: manager.webView) {
            $0.contains("Cannot Open Page") && $0.contains("Try Again")
        }
        let errorMarkup = try await manager.webView.evaluateJavaScript("document.documentElement.outerHTML") as? String ?? ""
        XCTAssertFalse(errorMarkup.contains(failedURL.absoluteString))
        XCTAssertFalse(errorMarkup.contains("PRIVATE_MARKER_71a9"))
        let errorSnapshot = try await manager.webView.takeSnapshot(configuration: nil)
        XCTAssertGreaterThan(errorSnapshot.size.width, 0)
        XCTAssertGreaterThan(errorSnapshot.size.height, 0)
        let href = try await manager.webView.evaluateJavaScript("document.querySelector('a').href") as? String
        XCTAssertEqual(href, "minis-browser://retry")

        // Exercise the actual in-document link, not only the native Retry control.
        try await manager.webView.evaluateJavaScript("document.querySelector('a').click()")
        let successDocument = try await waitForDOM(in: manager.webView) {
            $0.contains("fixture navigation recovered")
        }
        XCTAssertTrue(successDocument.contains("fixture navigation recovered"))
        XCTAssertNil(manager.loadError)
        XCTAssertEqual(schemeHandler.requestURLs, [failedURL, failedURL])
    }

    func testNavigationGateIgnoresSupersededStartAndTerminalCallbacks() {
        let oldNavigation = NSObject()
        let currentNavigation = NSObject()
        var gate = BrowserNavigationGate<NSObject>()

        gate.register(oldNavigation)
        gate.register(currentNavigation)

        XCTAssertFalse(gate.adoptStarted(oldNavigation), "A delayed old start must not replace the explicit current load")
        XCTAssertTrue(gate.matches(currentNavigation))
        XCTAssertFalse(gate.complete(oldNavigation), "An old terminal callback must not clear the current load")
        XCTAssertTrue(gate.matches(currentNavigation))
        XCTAssertTrue(gate.complete(currentNavigation))
        XCTAssertNil(gate.active)
        XCTAssertFalse(gate.adoptStarted(oldNavigation), "A delayed old start must stay retired after the current load finishes")
        XCTAssertFalse(gate.adoptStarted(currentNavigation), "A duplicate start must not resurrect a completed navigation")
    }

    func testMainFrameLinkCancelsPendingToolNavigationBeforeRetiringIt() async throws {
        let manager = BrowserUseManager()
        do {
            try await manager.navigationCompletion.wait {
                XCTAssertTrue(manager.navigationCompletion.isPending)
                manager.handleMainFrameLinkNavigation(to: URL(string: "https://example.invalid/user-link")!)
                if manager.navigationCompletion.isPending {
                    XCTFail("A user link must immediately release the superseded navigation")
                    manager.navigationCompletion.resolveAfterWebViewRemoval()
                }
            }
            XCTFail("A user link must cancel the superseded tool navigation")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertFalse(manager.navigationCompletion.isPending)
    }

    func testReplacingWebViewWithoutReloadURLReleasesPendingNavigationWaiter() async throws {
        let manager = BrowserUseManager()
        let waiting = Task { try await manager.navigationCompletion.wait() }
        await waitUntilPending(manager.navigationCompletion)

        manager.setViewport(width: 390, height: 844, profile: .mobileSafari, customUA: nil)

        do {
            try await waiting.value
            XCTFail("Replacing an empty WebView must not leave its waiter pending")
        } catch BrowserNavigationWaitError.webViewReplaced {
            // Expected: there was no requested URL to continue on the new view.
        }
        XCTAssertFalse(manager.navigationCompletion.isPending)
    }

    private func waitForDOM(in webView: WKWebView,
                            matching predicate: (String) -> Bool) async throws -> String {
        for _ in 0..<100 {
            if let text = try? await webView.evaluateJavaScript("document.body.innerText") as? String,
               predicate(text) { return text }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for expected WebView DOM")
        return (try? await webView.evaluateJavaScript("document.body.innerText") as? String) ?? ""
    }

    func testTimedOutNavigationIsFailureAndSkipsVisualFollowup() {
        let url = URL(string: "https://example.com/slow")!
        let result = BrowserUseManager.timedOutNavigationResult(for: url)

        XCTAssertFalse(result.success)
        XCTAssertTrue(result.text.contains("Navigation did not complete"))
        XCTAssertTrue(result.text.contains("DOM details and a preview snapshot were skipped"))
        XCTAssertEqual(result.pageURL, url.absoluteString)
        XCTAssertFalse(
            BrowserUseManager.shouldRunVisualFollowup(action: .navigate, result: result)
        )
    }

    func testSuccessfulNavigationStillRunsVisualFollowup() {
        let result = BrowserActionResult(text: "Navigated to https://example.com")

        XCTAssertTrue(
            BrowserUseManager.shouldRunVisualFollowup(action: .navigate, result: result)
        )
    }

    func testFailedVisualActionSkipsFollowup() {
        let result = BrowserActionResult.error("JavaScript timed out")

        XCTAssertFalse(
            BrowserUseManager.shouldRunVisualFollowup(action: .click, result: result)
        )
    }

    func testQueuedSuccessorRejectsReusedTabIDWithNewManager() {
        let tabId = 7
        let oldManager = BrowserUseManager()
        let replacementManager = BrowserUseManager()
        let replacementTab = BrowserTabPool.Tab(
            id: tabId,
            manager: replacementManager,
            inUse: true
        )

        XCTAssertEqual(replacementTab.id, tabId)
        XCTAssertNil(
            BrowserTabPool.matchingManagerIndex(
                for: tabId,
                manager: oldManager,
                in: [replacementTab]
            )
        )
        XCTAssertEqual(
            BrowserTabPool.matchingManagerIndex(
                for: tabId,
                manager: replacementManager,
                in: [replacementTab]
            ),
            0
        )
        XCTAssertNil(BrowserTabPool.matchingManagerIndex(for: tabId, manager: oldManager, in: []))
    }

    func testExpiredDeadlineBeforeMainActorMarkStillClassifiesCancellationAsTimeout() async throws {
        let completion = BrowserNavigationCompletion()
        completion.setDeadline(DispatchTime(uptimeNanoseconds: 0))
        let waiting = Task { try await completion.wait() }
        await waitUntilPending(completion)

        XCTAssertTrue(completion.resolveFromWebKit(error: URLError(.cancelled)))
        do {
            try await waiting.value
            XCTFail("A cancellation callback after the deadline must remain a timeout")
        } catch {
            XCTAssertTrue(BrowserUseManager.isNavigationDeadlineError(error))
        }
        XCTAssertFalse(BrowserUseManager.isNavigationDeadlineError(URLError(.cancelled)))
    }

    func testLateSuccessfulFinishClearsOverlayButKeepsToolResultFailed() async throws {
        let manager = BrowserUseManager()
        let url = URL(string: "https://example.com/slow")!
        let timedOutResult = BrowserUseManager.timedOutNavigationResult(for: url)
        manager.loadError = WebLoadError(error: URLError(.timedOut), failedURL: url)

        let waiting = Task { try await manager.navigationCompletion.wait() }
        await waitUntilPending(manager.navigationCompletion)
        XCTAssertTrue(manager.navigationCompletion.markDeadlineReached())

        let didFinishLate = manager.navigationDidFinish(
            url: url,
            title: "Loaded after deadline",
            canGoBack: false,
            canGoForward: false
        )

        XCTAssertTrue(didFinishLate)
        XCTAssertNil(manager.loadError)
        XCTAssertEqual(manager.currentURL, url.absoluteString)
        XCTAssertEqual(manager.pageTitle, "Loaded after deadline")
        XCTAssertFalse(timedOutResult.success)
        XCTAssertFalse(manager.navigationCompletion.isPending)

        do {
            try await waiting.value
            XCTFail("A navigation that missed its deadline must remain a failed tool action")
        } catch BrowserNavigationWaitError.navigationTimedOut {
            // The deadline stays failed even though the page later finished.
        } catch {
            XCTFail("Unexpected navigation completion error: \(error)")
        }
    }

    func testWebKitTerminalCallbackResolvesTimeoutOnlyOnce() async throws {
        let completion = BrowserNavigationCompletion()
        let waiting = Task { try await completion.wait() }
        await waitUntilPending(completion)
        XCTAssertTrue(completion.markDeadlineReached())

        XCTAssertTrue(completion.resolveFromWebKit(error: URLError(.cancelled)))
        XCTAssertFalse(completion.resolveFromWebKit())
        XCTAssertFalse(completion.resolveAfterWebViewRemoval())
        XCTAssertFalse(completion.isPending)

        do {
            try await waiting.value
            XCTFail("A timed-out navigation must not resolve as success")
        } catch BrowserNavigationWaitError.navigationTimedOut {
            // The completion object carries the deadline state across the callback.
        } catch {
            XCTFail("Unexpected navigation completion error: \(error)")
        }
    }

    func testImmediateTerminalCallbackDuringStartIsNotLost() async throws {
        let completion = BrowserNavigationCompletion()
        let waiting = Task {
            try await completion.wait {
                XCTAssertFalse(completion.resolveFromWebKit())
            }
        }

        try await waiting.value
        XCTAssertFalse(completion.isPending)
    }

    func testDeadTimeoutRemovalReleasesPendingWaitExactlyOnce() async throws {
        let completion = BrowserNavigationCompletion()
        let waiting = Task { try await completion.wait() }
        await waitUntilPending(completion)
        XCTAssertTrue(completion.markDeadlineReached())

        XCTAssertTrue(completion.resolveAfterWebViewRemoval())
        XCTAssertFalse(completion.resolveAfterWebViewRemoval())
        XCTAssertFalse(completion.resolveFromWebKit())
        XCTAssertFalse(completion.isPending)

        do {
            try await waiting.value
            XCTFail("A dead-tab removal after the navigation deadline must remain a timeout")
        } catch BrowserNavigationWaitError.navigationTimedOut {
            // Removing a dead WebView after its deadline still reports timeout.
        } catch {
            XCTFail("Unexpected navigation completion error: \(error)")
        }
    }

    func testOrdinaryWebViewRemovalReleasesPendingWaitOnce() async throws {
        let completion = BrowserNavigationCompletion()
        let waiting = Task { try await completion.wait() }
        await waitUntilPending(completion)

        XCTAssertTrue(completion.resolveAfterWebViewRemoval())
        XCTAssertFalse(completion.resolveAfterWebViewRemoval())
        XCTAssertFalse(completion.resolveFromWebKit())
        XCTAssertFalse(completion.isPending)

        do {
            try await waiting.value
            XCTFail("Removing the WebView must end its abandoned navigation wait")
        } catch BrowserNavigationWaitError.webViewRemoved {
            // Expected: the pool already removed this manager before resolving it.
        }
    }

    func testStopWithoutTerminalCallbackThenIdleEvictionReleasesWaiterOnce() async throws {
        try await assertStopWithoutTerminalCallbackThenRemovalReleasesWaiter { pool, _ in
            pool.evictIdleTabs()
        }
    }

    func testStopWithoutTerminalCallbackThenRegistryIdleEvictionReleasesWaiterOnce() async throws {
        try await assertStopWithoutTerminalCallbackThenRemovalReleasesWaiter { pool, tabId in
            pool.evictTabForRegistry(id: tabId)
        }
    }

    func testStopWithoutTerminalCallbackThenMemoryWarningEvictionReleasesWaiterOnce() async throws {
        try await assertStopWithoutTerminalCallbackThenRemovalReleasesWaiter { pool, _ in
            XCTAssertEqual(pool.evictAllIdleForMemoryWarning(), 1)
        }
    }

    private func assertStopWithoutTerminalCallbackThenRemovalReleasesWaiter(
        _ removeTab: (BrowserTabPool, Int) -> Void
    ) async throws {
        let pool = BrowserTabPool()
        let manager = BrowserUseManager()
        manager.currentURL = "https://example.com/slow"
        manager.isLoading = true
        var tab = BrowserTabPool.Tab(id: 7, manager: manager, inUse: false)
        tab.lastActivityDate = Date().addingTimeInterval(-BrowserTabPool.idleTimeout - 1)
        pool.tabs = [tab]

        let waiting = Task { try await manager.navigationCompletion.wait() }
        await waitUntilPending(manager.navigationCompletion)

        XCTAssertEqual(pool.stopAllLoading(), 1)
        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(manager.navigationCompletion.isPending)
        XCTAssertEqual(pool.tabs.count, 1)

        removeTab(pool, 7)

        XCTAssertTrue(pool.tabs.isEmpty)
        XCTAssertFalse(manager.navigationCompletion.isPending)
        XCTAssertFalse(manager.navigationCompletion.resolveAfterWebViewRemoval())
        do {
            try await waiting.value
            XCTFail("Idle eviction must end the wait after stop produced no terminal callback")
        } catch BrowserNavigationWaitError.webViewRemoved {
            // Expected: the idle eviction removed this manager before resolving it.
        }
    }

    private func waitUntilPending(_ completion: BrowserNavigationCompletion) async {
        for _ in 0..<100 where !completion.isPending {
            await Task.yield()
        }
        XCTAssertTrue(completion.isPending, "The navigation waiter should be installed")
    }
}
/// Deterministic WebKit navigation fixture: first request fails, retry succeeds.
private final class BrowserRecoveryFixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private var urls: [URL] = []
    var requestURLs: [URL] {
        lock.lock()
        defer { lock.unlock() }
        return urls
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: any WKURLSchemeTask) {
        lock.lock()
        urls.append(urlSchemeTask.request.url!)
        let requestNumber = urls.count
        lock.unlock()
        guard requestNumber > 1 else {
            urlSchemeTask.didFailWithError(URLError(.cannotConnectToHost))
            return
        }
        let data = Data("<html><body>fixture navigation recovered</body></html>".utf8)
        let response = URLResponse(url: urlSchemeTask.request.url!, mimeType: "text/html",
                                   expectedContentLength: data.count, textEncodingName: "utf-8")
        urlSchemeTask.didReceive(response)
        urlSchemeTask.didReceive(data)
        urlSchemeTask.didFinish()
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: any WKURLSchemeTask) {}
}
