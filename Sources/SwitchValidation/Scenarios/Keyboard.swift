import Foundation
import SwitchCore

typealias KeyStroke = KeyboardLayout.KeyStroke

/// Text ↔ physical keystrokes for one installed layout.
final class PhysicalKeyboard {
    let layout: KeyboardLayout
    private var strokes: [Character: KeyStroke] = [:]
    private static let apostrophes: Set<Character> = ["'", "’", "ʼ", "‘"]

    init(_ layout: KeyboardLayout) {
        self.layout = layout
        // Same preference as the app's own table: main keys, unshifted first.
        for shift in [false, true] {
            for key in Array(UInt16(0)...50) + [93, 94] {
                guard let value = layout.character(key: key, shift: shift), value.count == 1,
                      let character = value.first, strokes[character] == nil else { continue }
                strokes[character] = KeyStroke(key: key, shift: shift)
            }
        }
        // A typographic apostrophe is typed with whatever apostrophe key this layout has.
        if let own = Self.apostrophes.first(where: { strokes[$0] != nil }), let stroke = strokes[own] {
            for glyph in Self.apostrophes where strokes[glyph] == nil { strokes[glyph] = stroke }
        }
    }

    func stroke(for character: Character) -> KeyStroke? { strokes[character] }

    func strokes(for text: String) -> [KeyStroke]? {
        var result: [KeyStroke] = []
        for character in text {
            guard let stroke = strokes[character] else { return nil }
            result.append(stroke)
        }
        return result
    }

    func render(_ stroke: KeyStroke) -> String? { layout.character(key: stroke.key, shift: stroke.shift) }

    func render(_ strokes: [KeyStroke]) -> String? { layout.render(strokes) }

    func isLetter(_ stroke: KeyStroke) -> Bool { render(stroke)?.allSatisfy(\.isLetter) == true }
}

/// A realistic typing slip applied to the physical keys of one word.
struct Typo: Equatable {
    enum Kind: String, CaseIterable { case substitution, insertion, omission, duplication, transposition }
    let kind: Kind
    let position: Int
    let strokes: [KeyStroke]

    /// Every single slip of a word's letter keys: a neighbouring key instead of or next
    /// to the intended one, a skipped, doubled or swapped key. Only letter-producing
    /// keys are touched, so punctuation and the word length class stay realistic.
    static func all(_ word: [KeyStroke], keyboard: PhysicalKeyboard) -> [Typo] {
        var result: [Typo] = []
        var seen: Set<String> = []
        func add(_ kind: Kind, _ position: Int, _ strokes: [KeyStroke]) {
            guard strokes != word, let text = keyboard.render(strokes), seen.insert(text).inserted else { return }
            result.append(Typo(kind: kind, position: position, strokes: strokes))
        }
        if let text = keyboard.render(word) { seen.insert(text) }
        for (i, stroke) in word.enumerated() where keyboard.isLetter(stroke) {
            let near = (KeyboardGeometry.neighbours[stroke.key] ?? [])
                .map { KeyStroke(key: $0, shift: stroke.shift) }.filter(keyboard.isLetter)
            for other in near {
                var replaced = word; replaced[i] = other; add(.substitution, i, replaced)
                var before = word; before.insert(other, at: i); add(.insertion, i, before)
                var after = word; after.insert(other, at: i + 1); add(.insertion, i, after)
            }
            if word.count > 2 { var missing = word; missing.remove(at: i); add(.omission, i, missing) }
            var doubled = word; doubled.insert(stroke, at: i); add(.duplication, i, doubled)
            if i + 1 < word.count, keyboard.isLetter(word[i + 1]), word[i + 1] != stroke {
                var swapped = word; swapped.swapAt(i, i + 1); add(.transposition, i, swapped)
            }
        }
        return result
    }

    /// One slip chosen reproducibly, with kinds equally likely.
    static func sample(_ word: [KeyStroke], keyboard: PhysicalKeyboard, random: inout ValidationRandom) -> Typo? {
        let options = all(word, keyboard: keyboard)
        guard !options.isEmpty else { return nil }
        let kinds = Kind.allCases.filter { kind in options.contains { $0.kind == kind } }
        let kind = kinds[random.index(kinds.count)]
        let matching = options.filter { $0.kind == kind }
        return matching[random.index(matching.count)]
    }
}
