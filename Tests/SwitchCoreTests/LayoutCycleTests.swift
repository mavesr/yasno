import XCTest
@testable import SwitchCore

final class LayoutCycleTests: XCTestCase {
    let abc = "com.apple.keylayout.ABC"
    let ru = "com.apple.keylayout.Russian"
    let uk = "com.apple.keylayout.Ukrainian"

    func testEmptyFieldVisitsAllThreeLayoutsRepeatedly() throws {
        let cycle = LayoutCycle(layoutIDs: [abc, ru, uk])
        var current = abc
        for expected in [ru, uk, abc, ru, uk, abc] {
            current = try XCTUnwrap(cycle.next(after: current))
            XCTAssertEqual(current, expected)
        }
    }

    func testSmartFirstUkrainianStillAllowsRussianOnNextPress() {
        let cycle = LayoutCycle(layoutIDs: [abc, ru, uk], startingID: abc, firstTargetID: uk)
        XCTAssertEqual(cycle.next(after: abc), uk)
        XCTAssertEqual(cycle.next(after: uk), ru)
        XCTAssertEqual(cycle.next(after: ru), abc)
    }

    func testAfterAutomaticUndoEnglishCanAdvanceToRussian() {
        let cycle = LayoutCycle(layoutIDs: [abc, ru, uk])
        XCTAssertEqual(cycle.next(after: abc), ru)
    }

    func testCycleDoesNotDuplicateLayoutsOrSwitchToDisabledLayout() {
        let cycle = LayoutCycle(layoutIDs: [abc, uk, abc], startingID: abc, firstTargetID: ru)
        XCTAssertEqual(cycle.layoutIDs, [abc, uk])
        XCTAssertEqual(cycle.next(after: abc), uk)
        XCTAssertNil(LayoutCycle(layoutIDs: [abc, abc]).next(after: abc))
    }

    func testOriginalKeysCanBeReconvertedToEveryTarget() throws {
        let layouts = KeyboardLayout.installed(enabledOnly: false)
        let source = try XCTUnwrap(layouts.first { $0.id == abc })
        let russian = try XCTUnwrap(layouts.first { $0.id == ru })
        let ukrainian = try XCTUnwrap(layouts.first { $0.id == uk })
        XCTAssertEqual(source.convert("ghbdtn", to: ukrainian), "прівет")
        XCTAssertEqual(source.convert("ghbdtn", to: russian), "привет")
        XCTAssertEqual(source.convert("ghbdtn", to: source), "ghbdtn")
        XCTAssertEqual(KeyboardLayout.cycleOrder([ukrainian, source, russian]).map(\.id), [abc, ru, uk])
    }
}
