import Foundation
import SwitchCore

/// Types physical keys into a virtual text field the way KeyboardMonitor and AppModel
/// handle them: a word token grows key by key, a typing pause asks for a live
/// correction once the token has four characters, Space completes it, a correction
/// replaces exactly the token and selects the target layout, and the next keys are
/// rendered by that layout. Decisions go through Detector.mayCorrect/correction,
/// the same calls the app makes. Accessibility timing, focus and replay are covered
/// by the XCTest suites and are not modelled here.
final class TypingSimulator {
    enum Step: Equatable {
        case key(KeyStroke)
        case space
        /// The user selects this layout by hand before the next word, if it is not active.
        case ensure(String)
    }

    struct Edit {
        let original: String
        let replacement: String
        let live: Bool
    }

    struct Outcome {
        let text: String
        let edits: [Edit]
        let finalLayout: String
    }

    let detector: Detector
    let layouts: [KeyboardLayout]
    let correctSpelling: Bool
    /// True models a pause after every key, the most eager live-correction schedule.
    let liveTicks: Bool

    init(detector: Detector, layouts: [KeyboardLayout], correctSpelling: Bool = true, liveTicks: Bool = true) {
        self.detector = detector; self.layouts = layouts
        self.correctSpelling = correctSpelling; self.liveTicks = liveTicks
    }

    func type(_ steps: [Step], start: KeyboardLayout, preferred initialPreference: String?) -> Outcome {
        var field: [Character] = []
        var active = start
        var preferred = initialPreference
        var token = "", tokenStart = 0, liveConverted = false
        var edits: [Edit] = []

        func decide(whileTyping: Bool) {
            let request = CorrectionRequest(text: token, source: active, layouts: layouts,
                                            preferredTargetID: preferred, correctSpelling: correctSpelling,
                                            whileTyping: whileTyping, liveConverted: liveConverted)
            guard detector.mayCorrect(request) else { return }
            // AppModel refuses a token that continues existing text to its left.
            if tokenStart > 0, !TextSafety.hasLeftBoundary(String(field[tokenStart - 1])) { return }
            var context = String(field[..<tokenStart])
            while context.utf16.count > 256 { context.removeFirst() }
            guard let suggestion = detector.correction(request, context: context) else { return }
            let tokenCount = token.count
            guard tokenStart + tokenCount <= field.count else { return }
            field.replaceSubrange(tokenStart..<(tokenStart + tokenCount), with: Array(suggestion.replacement))
            edits.append(Edit(original: token, replacement: suggestion.replacement, live: whileTyping))
            active = suggestion.target
            if whileTyping { token = suggestion.replacement; liveConverted = true }
        }

        for step in steps {
            switch step {
            case .ensure(let id):
                guard token.isEmpty, active.id != id, let layout = layouts.first(where: { $0.id == id }) else { continue }
                active = layout
                // AppModel.sourceChanged: a manual Cyrillic choice becomes the preference.
                if layout.languages.contains(where: { $0 == .russian || $0 == .ukrainian }) { preferred = layout.id }
            case .space:
                field.append(" ")
                if !token.isEmpty { decide(whileTyping: false) }
                token = ""; liveConverted = false
            case .key(let stroke):
                guard let glyph = active.character(key: stroke.key, shift: stroke.shift) else {
                    token = ""; liveConverted = false; continue
                }
                if token.isEmpty { tokenStart = field.count; liveConverted = false }
                field.append(contentsOf: glyph)
                token += glyph
                if liveTicks, !liveConverted, token.count >= 4 { decide(whileTyping: true) }
            }
        }
        return Outcome(text: String(field), edits: edits, finalLayout: active.id)
    }
}

/// The keys a user presses for an intended text: each word is typed with the keys of
/// the layout that writes its script, whatever layout is actually active.
struct TypingPlan {
    struct Word {
        let text: String
        let layout: String
        let strokes: [KeyStroke]
    }
    let words: [Word]

    /// Nil when some character cannot be typed in its intended layout.
    static func make(_ text: String, keyboards: [String: PhysicalKeyboard], cyrillic: String, latin: String) -> TypingPlan? {
        var words: [Word] = []
        var previous = cyrillic
        for raw in text.split(separator: " ") {
            let word = String(raw)
            let layout: String
            if word.contains(where: Script.isCyrillic) { layout = cyrillic }
            else if word.contains(where: Script.isLatin) { layout = latin }
            else { layout = previous }
            previous = layout
            guard let strokes = keyboards[layout]?.strokes(for: word) else { return nil }
            words.append(Word(text: word, layout: layout, strokes: strokes))
        }
        return words.isEmpty ? nil : TypingPlan(words: words)
    }

    /// Words separated by Space, with a final Space: the user goes on typing, so the
    /// last word is completed too. `ensureLayouts` models a user who always selects
    /// the right layout before a word; otherwise the active layout is left to the app.
    func steps(ensureLayouts: Bool, replacing index: Int? = nil, with strokes: [KeyStroke] = []) -> [TypingSimulator.Step] {
        var result: [TypingSimulator.Step] = []
        for (i, word) in words.enumerated() {
            if ensureLayouts { result.append(.ensure(word.layout)) }
            result += (i == index ? strokes : word.strokes).map { .key($0) }
            result.append(.space)
        }
        return result
    }
}

enum Script {
    static func isCyrillic(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x400...0x4ff).contains($0.value) }
    }
    static func isLatin(_ c: Character) -> Bool {
        c.isLetter && c.unicodeScalars.allSatisfy { $0.value < 0x250 }
    }
}
