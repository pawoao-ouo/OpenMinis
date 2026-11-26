import XCTest
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
