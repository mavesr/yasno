import Foundation

/// Human-readable report.md for a scenario run.
public enum ScenarioSummary {
    private static let sections: [(prefix: String, title: String, note: String)] = [
        ("sentence", "Real sentences, typed key by key",
         "native: the right layout before every word, nothing may change. wrong-*: the whole sentence starts in that layout. opposite-preference: the remembered Cyrillic layout is the other language. typo: one realistic slip in one word. Missed = only the slip is left; Different = some other text changed."),
        ("word", "Vocabulary sweep",
         "clean-native: a dictionary or real-text word typed correctly must stay. clean-wrong / title-wrong: the same word typed in the wrong layout must be converted."),
        ("typo", "Every one-key slip of the vocabulary, by oracle verdict",
         "recoverable: the intended word is the only dictionary word one edit away. ambiguous: several are. misleading: one different word is. valid-word: the slip is itself a word and must stay. unreachable: no dictionary word is one edit away. Missed = left as typed; Different = changed to something else."),
        ("double-typo", "Two slips in one word", "Rarely recoverable by a one-edit corrector; Different shows text turned into something unrelated."),
        ("stability", "Stability", "A corrected word typed again in the layout it ended in must not change again."),
        ("real-typo", "Real misspellings (Kartaslov, codespell, treebank annotations)", "Same verdicts as above."),
    ]

    public static func markdown(_ report: ScenarioReport) -> String {
        var text = "# Yasno scenario validation\n\n"
        text += "Profile: \(report.profile); seed: \(report.seed); sessions: \(report.sessions); elapsed: \(Int(report.durationSeconds)) s.\n\n"
        if !report.skipped.isEmpty {
            text += "Skipped (not typeable in the intended layout): " +
                report.skipped.keys.sorted().map { "\($0) \(report.skipped[$0]!)" }.joined(separator: ", ") + ".\n\n"
        }
        for section in sections {
            let keys = report.categories.keys.filter { $0.hasPrefix(section.prefix + "/") }.sorted()
            guard !keys.isEmpty else { continue }
            text += "## \(section.title)\n\n\(section.note)\n\n"
            text += "| Category | Checks | Passed | Missed | Different | Into another word | Passed % | Different % | Words | Wrong words |\n"
            text += "|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|\n"
            for key in keys {
                let c = report.categories[key]!
                let words = report.words[key]
                func percent(_ value: Int) -> String {
                    c.total == 0 ? "–" : String(format: "%.2f", Double(value) * 100 / Double(c.total))
                }
                text += "| \(key) | \(c.total) | \(c.passed) | \(c.missed) | \(c.different) | \(report.intoOtherWord[key] ?? 0) | \(percent(c.passed)) | \(percent(c.different)) | "
                text += "\(words.map { String($0.words) } ?? "") | \(words.map { String($0.wrongWords) } ?? "") |\n"
            }
            text += "\n"
        }
        text += "Total: \(report.total.total) checks; passed \(report.total.passed), missed \(report.total.missed), different \(report.total.different).\n\n"
        text += "\(report.scope)\n\nfailures.jsonl holds every non-passing sentence and every word-level case that changed text into something other than intended. Replay one with the same profile/seed and --case ID.\n"
        return text
    }
}
