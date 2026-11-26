import XCTest
import UIKit
import WebKit
import Network
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
        XCTAssertTrue(href == "minis-browser://retry", "The link must target the local browser retry route")

        // Exercise the actual in-document link, not only the native Retry control.
        try await manager.webView.evaluateJavaScript("document.querySelector('a').click()")
        let successDocument = try await waitForDOM(in: manager.webView) {
            $0.contains("fixture navigation recovered")
                && !manager.isLoading
                && manager.loadError == nil
                && !manager.isRetryingFailedLoad
        }
        XCTAssertTrue(successDocument.contains("fixture navigation recovered"))
        XCTAssertTrue(manager.loadError == nil, "In-document Retry must clear the error")
        XCTAssertTrue(schemeHandler.requestURLs == [failedURL, failedURL],
                      "In-document Retry must use the exact failed address")
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

    private func waitForRetryErrorDocumentReplacement(
        in webView: WKWebView,
        manager: BrowserUseManager
    ) async throws -> Bool {
        for _ in 0..<100 {
            if let isNewRetryDocument = try? await webView.evaluateJavaScript("""
                document.querySelector('meta[name="minis-browser-error"]') !== null
                && document.querySelector('a[href="minis-browser://retry"]') !== null
                && document.documentElement.getAttribute('data-retry-test-document') === null
                """) as? Bool,
               isNewRetryDocument,
               manager.loadError != nil,
               !manager.isLoading,
               !manager.isRetryingFailedLoad {
                return true
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
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
/// Deterministic WebKit fixture: fail a configured number of loads, then succeed.
private final class BrowserRecoveryFixtureSchemeHandler: NSObject, WKURLSchemeHandler {
    private let lock = NSLock()
    private let failuresBeforeSuccess: Int
    private var urls: [URL] = []

    init(failuresBeforeSuccess: Int = 1) {
        self.failuresBeforeSuccess = failuresBeforeSuccess
        super.init()
    }

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
        guard requestNumber > failuresBeforeSuccess else {
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

@MainActor
extension BrowserNavigateTimeoutTests {
    func testRebuiltWebViewDoesNotTreatOldViewPageAsStillVisible() async throws {
        let fixture = try await LoopbackHTTPRecoveryFixture.start()
        defer { fixture.stop() }
        let manager = BrowserUseManager(profile: .mobileSafari, customString: nil)
        manager.loadURL("http://127.0.0.1:\(fixture.port)/existing-page")
        _ = try await waitForDOM(in: manager.webView) { $0.contains("existing page remains usable") }
        for _ in 0..<200 where manager.isLoading {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(manager.isLoading, "The original page must finish before the view is rebuilt")

        fixture.disableExistingPage()
        let oldWebView = manager.webView
        manager.setViewport(width: 390, height: 844, profile: .mobileSafari, customUA: nil)
        XCTAssertFalse(manager.webView === oldWebView, "The test must exercise a replacement WebView")
        try await waitUntilManagerShowsFailure(manager)
        let failureDOM = try await waitForDOM(in: manager.webView) { $0.contains(AppLocalized("Try Again")) }
        XCTAssertTrue(failureDOM.contains(AppLocalized("Try Again")), "A failed reload in a new view must show its error and retry")
        XCTAssertFalse(failureDOM.contains("existing page remains usable"))
        XCTAssertGreaterThanOrEqual(fixture.requestTargets.filter { $0 == "/existing-page" }.count, 2)
    }

    func testProvisionalFailureWithNoBackHistoryKeepsExistingPageDOMVisible() async throws {
        let fixture = try await LoopbackHTTPRecoveryFixture.start()
        defer { fixture.stop() }
        let manager = BrowserUseManager(profile: .mobileSafari, customString: nil)
        let originalURL = "http://127.0.0.1:\(fixture.port)/existing-page"
        manager.loadURL(originalURL)
        let originalDOM = try await waitForDOM(in: manager.webView) {
            $0.contains("existing page remains usable")
        }
        XCTAssertTrue(originalDOM.contains("existing page remains usable"))
        XCTAssertFalse(manager.webView.canGoBack, "The setup must exercise the canGoBack=false case")

        manager.loadURL("http://127.0.0.1:\(fixture.port)/provisional-failure")
        try await waitUntilFailedRequestSettles(manager, fixture: fixture)
        try await Task.sleep(nanoseconds: 250_000_000)
        let retainedDOM = try await waitForDOM(in: manager.webView) {
            $0.contains("existing page remains usable")
        }
        XCTAssertTrue(retainedDOM.contains("existing page remains usable"), "A real provisional failure must leave the previously rendered page usable")
        XCTAssertFalse(retainedDOM.contains("Cannot Open Page"), "The failure UI must not replace the retained page")
        XCTAssertTrue(fixture.requestTargets.contains("/existing-page"))
        XCTAssertTrue(fixture.requestTargets.contains("/provisional-failure"), "The local server must observe the actual failed provisional request")
    }

    func testNativeRetryShowsFeedbackAndReissuesExactAddressAfterAnotherFailure() async throws {
        let schemeHandler = BrowserRecoveryFixtureSchemeHandler(failuresBeforeSuccess: 2)
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: "minis-clone")
        let manager = BrowserUseManager(profile: .mobileSafari, customString: nil, configuration: configuration)
        let requested = URL(string: "minis-clone://fixture/retry?secret=NATIVE_RETRY_46")!
        manager.loadURL(requested.absoluteString)
        try await waitUntilManagerShowsFailure(manager)

        let initialError = try XCTUnwrap(manager.loadError)
        XCTAssertTrue(initialError.failedURL == requested, "The initial failure must retain the exact requested address")
        XCTAssertFalse(manager.isLoading)
        XCTAssertFalse(manager.isRetryingFailedLoad)
        let initialErrorDOM = try await waitForDOM(in: manager.webView) {
            $0.contains(AppLocalized("Try Again"))
        }
        XCTAssertTrue(initialErrorDOM.contains(AppLocalized("Try Again")))
        let initialErrorMarker = try await manager.webView.evaluateJavaScript(
            "document.querySelector('meta[name=\"minis-browser-error\"]') !== null"
        ) as? Bool
        XCTAssertEqual(initialErrorMarker, true, "The first retry prompt must be the browser's own error document")
        XCTAssertTrue(schemeHandler.requestURLs == [requested],
                      "The initial navigation must use the exact address once")
        let initialDocumentTagged = try await manager.webView.evaluateJavaScript("""
            document.documentElement.setAttribute('data-retry-test-document', 'initial');
            document.documentElement.getAttribute('data-retry-test-document') === 'initial'
            """) as? Bool
        guard initialDocumentTagged == true else {
            XCTFail("The initial error document must be tagged before retry")
            return
        }

        // This is the callback wired to the visible SwiftUI Retry button.
        // Keep the fixture failing once more so the test covers the no-change case.
        manager.retryFailedLoad()
        XCTAssertTrue(manager.isRetryingFailedLoad, "A tap must immediately show retry progress")
        XCTAssertTrue(manager.isLoading)
        XCTAssertTrue(manager.loadError == initialError, "Keep the explanation visible while retrying")
        try await waitUntilRequestCountAndNavigationSettles(2, manager: manager) {
            schemeHandler.requestURLs.count
        }
        let secondFailureDocumentInstalled = try await waitForRetryErrorDocumentReplacement(
            in: manager.webView,
            manager: manager
        )
        guard secondFailureDocumentInstalled else {
            XCTFail("A second failure must replace the prior error document with a fresh Retry page")
            return
        }
        XCTAssertNotNil(manager.loadError, "A second failure must leave the error card available")
        XCTAssertFalse(manager.isLoading)
        XCTAssertFalse(manager.isRetryingFailedLoad, "Retry must become available again after the failed attempt settles")
        let failedAgainDOM = try await waitForDOM(in: manager.webView) {
            $0.contains(AppLocalized("Try Again"))
        }
        XCTAssertTrue(failedAgainDOM.contains(AppLocalized("Try Again")))
        let failedAgainMarker = try await manager.webView.evaluateJavaScript(
            "document.querySelector('meta[name=\"minis-browser-error\"]') !== null"
        ) as? Bool
        XCTAssertEqual(failedAgainMarker, true, "A failed retry must keep the browser error document available")
        XCTAssertTrue(schemeHandler.requestURLs == [requested, requested],
                      "The failed retry must reuse the exact address")

        manager.retryFailedLoad()
        XCTAssertTrue(manager.isRetryingFailedLoad)
        XCTAssertTrue(manager.isLoading)
        XCTAssertNotNil(manager.loadError)
        let recovered = try await waitForDOM(in: manager.webView) {
            $0.contains("fixture navigation recovered")
                && !manager.isLoading
                && manager.loadError == nil
                && !manager.isRetryingFailedLoad
        }
        XCTAssertTrue(recovered.contains("fixture navigation recovered"))
        XCTAssertTrue(manager.loadError == nil, "A successful retry must clear the old failure")
        XCTAssertFalse(manager.isLoading)
        XCTAssertTrue(schemeHandler.requestURLs == Array(repeating: requested, count: 3),
                      "Initial navigation and both retries must use the exact same path and query")
    }

    func testRetryFeedbackResetsWhenWebContentProcessTerminates() {
        let manager = BrowserUseManager(profile: .mobileSafari, customString: nil)
        manager.retryFailedLoad()
        XCTAssertTrue(manager.isRetryingFailedLoad)

        manager.webViewWebContentProcessDidTerminate(manager.webView)

        XCTAssertFalse(manager.isRetryingFailedLoad, "A terminal WebContent failure must re-enable Retry")
        XCTAssertFalse(manager.isLoading)
        XCTAssertNotNil(manager.loadError)
        manager.stopLoading()
    }

    func testHTTPProvisionalFailureIsVisibleAndGetTextCanRetryExactAddress() async throws {
        let fixture = try await LoopbackHTTPRecoveryFixture.start()
        defer { fixture.stop() }
        let manager = BrowserUseManager(profile: .mobileSafari, customString: nil)
        let requested = "http://127.0.0.1:\(fixture.port)/retry?secret=LOOPBACK_PRIVATE_92"
        let expectedRequestTarget = "/retry?secret=LOOPBACK_PRIVATE_92"
        let input = try XCTUnwrap(BrowserActionInput.parse(from: """
        {"action":"navigate","url":"\(requested)"}
        """))

        do {
            let navigation = try await manager.execute(action: input)
            XCTAssertFalse(navigation.success, "The initial transport failure must not be reported as a successful navigation")
            XCTAssertFalse(navigation.text.contains("fixture success"), "The first request must fail before the retry is armed")
        } catch {
            // Ordinary WebKit failures are rethrown by navigate; either outcome
            // is acceptable only because this fixture deliberately closes TCP.
            XCTAssertFalse(BrowserUseManager.isNavigationDeadlineError(error), "The immediate fixture failure must not be mistaken for a timeout")
        }
        try await waitUntilManagerShowsFailure(manager)
        let failure = try XCTUnwrap(manager.loadError, "The HTTP failure must have a user-facing explanation")
        let failureDOM = try await waitForDOM(in: manager.webView) {
            $0.contains(failure.title) && $0.contains(failure.message) && $0.contains(AppLocalized("Try Again"))
        }
        XCTAssertTrue(failureDOM.contains(failure.title), "The failure title must be rendered")
        XCTAssertTrue(failureDOM.contains(failure.message), "The failure explanation must be rendered")
        XCTAssertTrue(failureDOM.contains(AppLocalized("Try Again")), "The localized in-WebView Retry control must be rendered")
        let loadingLabel = AppLocalized("Loading…")
        let loadingTextAttribute = try await manager.webView.evaluateJavaScript(
            "document.querySelector('a[href=\"minis-browser://retry\"]')?.getAttribute('data-loading-text')"
        ) as? String
        XCTAssertEqual(loadingTextAttribute, loadingLabel,
                       "The in-WebView Retry control must declare the loading label its click handler displays")
        let isFailureDocument = try await manager.webView.evaluateJavaScript("document.querySelector('meta[name=\"minis-browser-error\"]') !== null") as? Bool
        XCTAssertEqual(isFailureDocument, true, "The rendered Retry control must belong to the browser error document")
        XCTAssertFalse(failureDOM.contains("LOOPBACK_PRIVATE_92"), "The failed URL/query must not be exposed in the error document")

        let errorText = try await manager.execute(action: XCTUnwrap(BrowserActionInput.parse(from: """
        {"action":"get_text"}
        """)))
        XCTAssertTrue(errorText.success)
        XCTAssertTrue(errorText.text.contains(failure.title), "get_text must include the actual failure title")
        XCTAssertTrue(errorText.text.contains(failure.message), "get_text must include the actual failure explanation")
        XCTAssertTrue(errorText.text.localizedCaseInsensitiveContains(AppLocalized("Try Again")), "get_text must read the localized in-WebView failure UI")
        XCTAssertFalse(errorText.text.contains("LOOPBACK_PRIVATE_92"), "The failed URL/query must stay out of visible error content")
        let visibleElements = try await manager.webView.evaluateJavaScript("""
        ['h2', 'p', 'a'].every(selector => {
            const element = document.querySelector(selector);
            if (!element) return false;
            const rect = element.getBoundingClientRect();
            const style = getComputedStyle(element);
            return rect.width > 0 && rect.height > 0 && rect.left >= 0 && rect.top >= 0
                && rect.right <= innerWidth && rect.bottom <= innerHeight
                && style.display !== 'none' && style.visibility === 'visible' && Number(style.opacity) > 0;
        })
        """) as? Bool
        XCTAssertEqual(visibleElements, true, "The failure title, explanation and retry must fit within the visible viewport")

        let screenshotAction = try XCTUnwrap(BrowserActionInput.parse(from: """
        {"action":"screenshot"}
        """))
        let screenshotResult = try await manager.execute(action: screenshotAction)
        XCTAssertTrue(screenshotResult.success, "The browser screenshot action must succeed")
        let screenshotData = try XCTUnwrap(Data(base64Encoded: XCTUnwrap(screenshotResult.base64Image)))
        let screenshotPath = try XCTUnwrap(screenshotResult.imageFilePath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: screenshotPath)), screenshotData,
                       "The returned image and saved browser screenshot must be identical")
        let attachment = XCTAttachment(data: screenshotData, uniformTypeIdentifier: "public.jpeg")
        attachment.name = "browser-error-page-screenshot"
        attachment.lifetime = .keepAlways
        add(attachment)
        let screenshot = try XCTUnwrap(UIImage(data: screenshotData))
        XCTAssertGreaterThan(screenshot.size.width, 0)
        XCTAssertGreaterThan(screenshot.size.height, 0)
        let image = try XCTUnwrap(screenshot.cgImage, "WKWebView snapshot should provide rendered pixels")
        let bytesPerPixel = 4
        let bytesPerRow = image.width * bytesPerPixel
        var rgba = [UInt8](repeating: 0, count: image.height * bytesPerRow)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress,
                                          width: image.width,
                                          height: image.height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                                            | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        XCTAssertTrue(rendered, "Snapshot pixels should be renderable as tightly packed RGBA")
        var visiblyDarkPixels = 0
        var distinctlyColoredPixels = 0
        // Iterate only actual x/y pixel coordinates; bytesPerRow is deliberately
        // explicit so row padding can never be counted as image content.
        for y in 0..<image.height {
            for x in 0..<image.width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                let red = Int(rgba[offset])
                let green = Int(rgba[offset + 1])
                let blue = Int(rgba[offset + 2])
                let luminance = (red * 299 + green * 587 + blue * 114) / 1000
                if luminance < 190 { visiblyDarkPixels += 1 }
                if max(red, green, blue) - min(red, green, blue) > 45 { distinctlyColoredPixels += 1 }
            }
        }
        XCTAssertGreaterThan(visiblyDarkPixels, 100, "Rendered snapshot should contain substantial contrasting foreground content")
        XCTAssertGreaterThan(distinctlyColoredPixels, 20, "Rendered snapshot should contain the colored Retry control, not a blank canvas")

        fixture.allowSuccess()
        let click = try XCTUnwrap(BrowserActionInput.parse(from: """
        {"action":"click","selector":"a[href='minis-browser://retry']"}
        """))
        let clickResult = try await manager.execute(action: click)
        XCTAssertTrue(clickResult.success, "browser_use click should activate the in-document Retry link")
        let recovered = try await waitForDOM(in: manager.webView) {
            $0.contains("loopback recovery succeeded")
                && !manager.isLoading
                && manager.loadError == nil
                && !manager.isRetryingFailedLoad
        }
        XCTAssertTrue(recovered.contains("loopback recovery succeeded"))
        XCTAssertFalse(recovered.contains(AppLocalized("Try Again")), "The visible failure state must be gone after recovery")
        XCTAssertTrue(manager.loadError == nil, "A successful retry must clear the failure")
        XCTAssertTrue(fixture.requestTargets.contains(expectedRequestTarget), "The successful retry must reach the original path and query")
        XCTAssertTrue(fixture.requestTargets.allSatisfy { $0 == expectedRequestTarget },
                      "Every request and retry must preserve the exact original address path and query")
    }

    private func waitUntilFailedRequestSettles(
        _ manager: BrowserUseManager,
        fixture: LoopbackHTTPRecoveryFixture
    ) async throws {
        for _ in 0..<200 {
            if fixture.requestTargets.contains("/provisional-failure"), !manager.isLoading { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for the local provisional-failure callback to settle")
    }

    private func waitUntilRequestCountAndNavigationSettles(
        _ expectedCount: Int,
        manager: BrowserUseManager,
        requestCount: () -> Int
    ) async throws {
        for _ in 0..<200 {
            if requestCount() >= expectedCount && !manager.isLoading { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(expectedCount) requests and a terminal navigation callback")
    }

    private func waitUntilManagerShowsFailure(_ manager: BrowserUseManager) async throws {
        for _ in 0..<200 {
            if manager.loadError != nil { return }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for actual WKWebView HTTP failure (10 seconds)")
    }

}

/// Isolated ephemeral-port HTTP server. Its first request is closed without an
/// HTTP response (transport failure); after allowSuccess(), retry gets a page.
private final class LoopbackHTTPRecoveryFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let listener: NWListener
    private var successfulResponseEnabled = false
    private var existingPageEnabled = true
    private var requests = 0
    private var targets: [String] = []
    private var boundPort: UInt16 = 0
    var port: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return boundPort
    }

    var requestCount: Int {
        lock.lock(); defer { lock.unlock() }
        return requests
    }

    var requestTargets: [String] {
        lock.lock(); defer { lock.unlock() }
        return targets
    }

    private init(listener: NWListener) {
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in self?.handle(connection) }
    }

    static func start() async throws -> LoopbackHTTPRecoveryFixture {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host("127.0.0.1"), port: .any)
        let listener = try NWListener(using: parameters)
        let fixture = LoopbackHTTPRecoveryFixture(listener: listener)
        let gate = LoopbackReadyGate()
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard let port = listener.port?.rawValue else {
                        gate.resolve(.failure(NSError(domain: "LoopbackHTTPRecoveryFixture", code: 1)))
                        return
                    }
                    fixture.lock.lock()
                    fixture.boundPort = port
                    fixture.lock.unlock()
                    gate.resolve(.success(()))
                case .failed(let error):
                    gate.resolve(.failure(error))
                default:
                    break
                }
            }
            listener.start(queue: DispatchQueue(label: "BrowserNavigateTimeoutTests.loopback", qos: .userInitiated))
            Task {
                try await Task.sleep(nanoseconds: 5_000_000_000)
                gate.resolve(.failure(NSError(domain: "LoopbackHTTPRecoveryFixture", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: "Loopback listener did not bind within 5 seconds"])))
            }
            }
        } catch {
            fixture.stop()
            throw error
        }
        return fixture
    }

    func allowSuccess() {
        lock.lock(); successfulResponseEnabled = true; lock.unlock()
    }

    func disableExistingPage() {
        lock.lock(); existingPageEnabled = false; lock.unlock()
    }

    func stop() { listener.cancel() }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: DispatchQueue(label: "BrowserNavigateTimeoutTests.connection", qos: .userInitiated))
        receiveRequest(connection, accumulated: Data())
    }

    private func receiveRequest(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            guard let self else { connection.cancel(); return }
            var request = accumulated
            if let data { request.append(data) }
            guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                if complete || error != nil || request.count >= 8192 {
                    connection.cancel()
                } else {
                    self.receiveRequest(connection, accumulated: request)
                }
                return
            }
            let requestLine = String(data: request, encoding: .utf8)?
                .components(separatedBy: "\r\n").first ?? ""
            let target = requestLine.split(separator: " ").dropFirst().first.map(String.init) ?? ""
            self.lock.lock()
            self.requests += 1
            self.targets.append(target)
            let isExistingPage = target == "/existing-page"
            let shouldSucceed = (isExistingPage && self.existingPageEnabled) || self.successfulResponseEnabled
            self.lock.unlock()
            guard shouldSucceed else { connection.cancel(); return }
            let body = isExistingPage
                ? "<html><body>existing page remains usable</body></html>"
                : "<html><body>loopback recovery succeeded</body></html>"
            let response = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }
}

private final class LoopbackReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Void, Error>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}
