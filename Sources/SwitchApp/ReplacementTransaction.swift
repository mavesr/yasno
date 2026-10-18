import Foundation

/// Production editing state machine, with AX/clock/input effects supplied separately.
/// Tests exercise this same transaction with a virtual editor and clock, never a user app.
enum ReplacementTransaction {
    enum Result: Equatable { case success, stale, unsupported, failed }
    struct Environment {
        let selection: () -> CFRange?
        let text: (CFRange) -> String?
        let focused: () -> Bool
        let canSelect: () -> Bool
        let select: (CFRange) -> Bool
        let insert: (String) -> Bool
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var pause: () -> Void = { Thread.sleep(forTimeInterval: 0.004) }
        var timeout: TimeInterval = 0.25
        var deadline: TimeInterval? = nil
    }

    static func run(range: CFRange, expected: String, replacement: String, caret: CFRange,
                    stillValid: () -> Bool, commit: () -> Bool, environment e: Environment) -> Result {
        func same(_ lhs: CFRange?, _ rhs: CFRange) -> Bool { lhs?.location == rhs.location && lhs?.length == rhs.length }
        let deadline = e.deadline ?? e.now() + 0.5
        func valid() -> Bool { stillValid() && e.now() < deadline }
        guard range.location >= 0, range.length == expected.utf16.count, caret.location >= 0, caret.length >= 0,
              valid(), e.focused(), same(e.selection(), caret), e.text(range) == expected else { return .stale }
        if expected == replacement { return .success }
        guard e.canSelect() else { return .unsupported }
        guard valid(), e.select(range) else { return .stale }
        let selectionDeadline = min(deadline, e.now() + e.timeout)
        while !same(e.selection(), range), valid(), e.now() < selectionDeadline { e.pause() }
        func restoreIfOwned() {
            if e.focused(), same(e.selection(), range), e.text(range) == expected { _ = e.select(caret) }
        }
        guard valid(), e.focused(), same(e.selection(), range), e.text(range) == expected else {
            restoreIfOwned(); return .stale
        }
        guard valid(), commit(), e.insert(replacement) else { restoreIfOwned(); return .failed }
        let inserted = CFRange(location: range.location, length: replacement.utf16.count)
        let editDeadline = min(deadline, e.now() + e.timeout)
        // Focus is re-checked after the wait. Polling it here costs several AX requests to the
        // very renderer that is processing the insertion.
        while e.text(inserted) != replacement, valid(), e.now() < editDeadline { e.pause() }
        guard valid(), e.focused(), e.text(inserted) == replacement else { restoreIfOwned(); return .failed }
        let delta = replacement.utf16.count - expected.utf16.count
        let end = caret.length == 0 ? caret.location + delta : range.location + replacement.utf16.count
        let finalCaret = CFRange(location: end, length: 0)
        guard valid(), e.select(finalCaret) else { return .failed }
        let caretDeadline = min(deadline, e.now() + e.timeout)
        while !same(e.selection(), finalCaret), valid(), e.now() < caretDeadline { e.pause() }
        guard valid(), e.focused(), same(e.selection(), finalCaret) else { return .failed }
        return .success
    }
}
