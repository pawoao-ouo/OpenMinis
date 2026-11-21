import XCTest
@testable import Minis

/// Pins `AIChatViewModel.resolveWindow` — the pure half of
/// `resolvedContextWindow` (the instance method reads the live group limit
/// from the store; this helper is the testable seam).
///
/// WHY: the usage sheet showed a 200K window for her DeepSeek entry while
/// the model can only take 198K. Root cause: the group-limit override was
/// returned unclamped even when it exceeded the model's native window,
/// contradicting the doc comment on `resolvedContextWindow` itself
/// ("给 128K 模型设 200K 不是限制，是写错了，按原生窗口算").
/// A limit above native is a misconfiguration, not a bigger window.
@MainActor
final class ContextWindowResolutionTests: XCTestCase {

    func testNoLimitReturnsNative() {
        let r = AIChatViewModel.resolveWindow(native: 198_000, groupLimit: nil)
        XCTAssertEqual(r.window, 198_000)
        XCTAssertFalse(r.isUserCap)
    }

    func testLimitBelowNativeIsARealCap() {
        let r = AIChatViewModel.resolveWindow(native: 198_000, groupLimit: 128_000)
        XCTAssertEqual(r.window, 128_000)
        XCTAssertTrue(r.isUserCap)
    }

    func testLimitEqualToNativeIsNotACap() {
        let r = AIChatViewModel.resolveWindow(native: 128_000, groupLimit: 128_000)
        XCTAssertEqual(r.window, 128_000)
        XCTAssertFalse(r.isUserCap)
    }

    func testLimitAboveNativeClampsToNative() {
        // Her case: DeepSeek native 198K, group limit 200K. The sheet must
        // show 198K — the model cannot take 200K.
        let r = AIChatViewModel.resolveWindow(native: 198_000, groupLimit: 200_000)
        XCTAssertEqual(r.window, 198_000)
        XCTAssertFalse(r.isUserCap)
    }

    func testIntMaxSentinelMeansNoLimit() {
        // The slider's rightmost stop stores Int.max (see the doc comment on
        // effectiveContextWindow); it must not leak out as a real ceiling.
        let r = AIChatViewModel.resolveWindow(native: 198_000, groupLimit: Int.max)
        XCTAssertEqual(r.window, 198_000)
        XCTAssertFalse(r.isUserCap)
    }
}
