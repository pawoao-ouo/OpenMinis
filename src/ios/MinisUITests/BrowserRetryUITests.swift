import XCTest

@MainActor
final class BrowserRetryUITests: XCTestCase {
    func testNativeRetryButtonReissuesExactAddressAfterFailureAndRecovery() {
        let app = XCUIApplication()
        app.launchArguments = ["--uitest-browser-retry", "-appLanguage", "en"]
        app.launch()

        let retryButton = app.buttons["webLoadErrorRetry"]
        XCTAssertTrue(retryButton.waitForExistence(timeout: 10), "The native browser Retry button must be visible after the initial failure")
        XCTAssertTrue(retryButton.isEnabled)
        XCTAssertEqual(retryButton.label, "Try Again")

        let requestSummary = app.staticTexts["browserRetryRequestSummary"]
        let firstRequest = expectation(
            for: NSPredicate(format: "label == %@", "1|exact"),
            evaluatedWith: requestSummary
        )
        wait(for: [firstRequest], timeout: 3)
        XCTAssertEqual(requestSummary.label, "1|exact")

        retryButton.tap()

        let loadingLabel = expectation(
            for: NSPredicate(format: "label == %@", "Loading…"),
            evaluatedWith: retryButton
        )
        wait(for: [loadingLabel], timeout: 3)
        XCTAssertFalse(retryButton.isEnabled, "Retry must be disabled while the request is active")

        let secondRequest = expectation(
            for: NSPredicate(format: "label == %@", "2|exact"),
            evaluatedWith: requestSummary
        )
        wait(for: [secondRequest], timeout: 4)
        let retryAvailableAfterFailure = expectation(
            for: NSPredicate(format: "label == %@", "Try Again"),
            evaluatedWith: retryButton
        )
        wait(for: [retryAvailableAfterFailure], timeout: 5)
        XCTAssertTrue(retryButton.isEnabled, "A failed retry must leave the native action available")
        XCTAssertEqual(requestSummary.label, "2|exact")

        retryButton.tap()

        let recoveredPage = app.webViews.staticTexts["browser retry succeeded"]
        XCTAssertTrue(recoveredPage.waitForExistence(timeout: 5), "The next retry must load the successful response")
        let thirdRequest = expectation(
            for: NSPredicate(format: "label == %@", "3|exact"),
            evaluatedWith: requestSummary
        )
        wait(for: [thirdRequest], timeout: 3)
        XCTAssertEqual(requestSummary.label, "3|exact",
                       "The initial navigation and both button taps must match the fixture address")
    }
}
