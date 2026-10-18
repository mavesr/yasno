import XCTest
@testable import SwitchCore

final class ShiftTapTests: XCTestCase {
    func testSingleTapWorksWithEitherShift() {
        for key in [UInt16(56), 60] {
            var gesture = ShiftTapGesture()
            gesture.press(key: key, at: 1)
            XCTAssertTrue(gesture.release(key: key, at: 1.12))
            XCTAssertFalse(gesture.release(key: key, at: 1.13))
        }
    }

    func testUppercaseAndSelectionChordsNeverSwitch() {
        var gesture = ShiftTapGesture()
        gesture.press(key: 56, at: 1)
        gesture.cancel() // Letter, arrow, or mouse action while Shift is held.
        XCTAssertFalse(gesture.release(key: 56, at: 1.2))
        gesture.press(key: 56, at: 2)
        XCTAssertTrue(gesture.release(key: 56, at: 2.1))
    }

    func testOtherModifiersBeforeOrDuringShiftCancelTap() {
        var gesture = ShiftTapGesture()
        gesture.press(key: 56, at: 1, clean: false) // Cmd/Option/Ctrl/Fn already held.
        XCTAssertFalse(gesture.release(key: 56, at: 1.1))
        gesture.press(key: 56, at: 2)
        gesture.cancel() // Another modifier pressed and released before Shift.
        XCTAssertFalse(gesture.release(key: 56, at: 2.1))
        gesture.press(key: 56, at: 3)
        XCTAssertFalse(gesture.release(key: 56, at: 3.1, clean: false))
    }

    func testLongHoldIsNotATapAndDoesNotBlockTheNextTap() {
        var gesture = ShiftTapGesture()
        gesture.press(key: 56, at: 1)
        XCTAssertFalse(gesture.release(key: 56, at: 1.6))
        gesture.press(key: 56, at: 2)
        XCTAssertTrue(gesture.release(key: 56, at: 2.2))
    }

    func testOverlappingShiftKeysDoNotSwitch() {
        var gesture = ShiftTapGesture()
        gesture.press(key: 56, at: 1)
        gesture.press(key: 60, at: 1.05)
        gesture.press(key: 56, at: 1.1) // Left released, aggregate Shift flag still set.
        XCTAssertFalse(gesture.release(key: 60, at: 1.15))
        gesture.press(key: 60, at: 2)
        XCTAssertTrue(gesture.release(key: 60, at: 2.1))
    }

    func testDuplicateDownCannotBecomeAShortTapAfterALongHold() {
        var gesture = ShiftTapGesture()
        gesture.press(key: 56, at: 1)
        gesture.press(key: 56, at: 2)
        XCTAssertFalse(gesture.release(key: 56, at: 2.1))
    }

    func testFocusChangeAndUnmatchedReleaseDoNotSwitch() {
        var gesture = ShiftTapGesture()
        XCTAssertFalse(gesture.release(key: 56, at: 1))
        gesture.press(key: 56, at: 2)
        gesture.reset()
        XCTAssertFalse(gesture.release(key: 56, at: 2.1))
        gesture.press(key: 56, at: 3)
        XCTAssertFalse(gesture.release(key: 60, at: 3.1))
    }

    func testTwoFastTapsAreTwoDeliberateActions() {
        var gesture = ShiftTapGesture()
        gesture.press(key: 56, at: 1)
        XCTAssertTrue(gesture.release(key: 56, at: 1.07))
        gesture.press(key: 56, at: 1.16)
        XCTAssertTrue(gesture.release(key: 56, at: 1.23))
    }
}
