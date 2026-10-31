import Foundation

/// One typed word as the app sees it. AppModel and the scenario simulator both
/// decide through the two Detector methods below, so simulated runs exercise the
/// shipped decision rather than a copy of it.
public struct CorrectionRequest {
    public let text: String
    public let source: KeyboardLayout
    public let layouts: [KeyboardLayout]
    public let ignored: Set<String>
    public let preferredTargetID: String?
    public let correctSpelling: Bool
    public let whileTyping: Bool
    /// The word was already converted while typing and is being continued.
    public let liveConverted: Bool
    /// Typing stopped on a word too short to be checked while it is typed.
    public let paused: Bool

    public init(text: String, source: KeyboardLayout, layouts: [KeyboardLayout], ignored: Set<String> = [],
                preferredTargetID: String?, correctSpelling: Bool, whileTyping: Bool, liveConverted: Bool = false,
                paused: Bool = false) {
        // An exception written with one apostrophe also covers the others (п'ятниця, п’ятниця).
        self.text = text; self.source = source; self.layouts = layouts
        self.ignored = ignored.union(ignored.map { WordText.canonical($0.lowercased()) })
        self.preferredTargetID = preferredTargetID; self.correctSpelling = correctSpelling
        self.whileTyping = whileTyping; self.liveConverted = liveConverted; self.paused = paused
    }

    func with(text: String) -> CorrectionRequest {
        CorrectionRequest(text: text, source: source, layouts: layouts, ignored: ignored, preferredTargetID: preferredTargetID,
                          correctSpelling: correctSpelling, whileTyping: whileTyping, liveConverted: liveConverted, paused: paused)
    }

    /// The whole text as typed is an exception, checked before any symbols around it are
    /// set aside: #ghbdtn listed as is stays #ghbdtn.
    var isIgnored: Bool {
        ignored.contains(text.lowercased()) || ignored.contains(WordText.canonical(text.lowercased()))
    }

    /// Symbols before a word (/вумудщзук → /developer, «руддщ → «hello) stay as typed and the
    /// word after them is judged alone, exactly as if typed after a space. Not when another
    /// layout puts a letter on that key: [jxe is хочу.
    var openingSymbols: String? {
        let prefix = String(text.prefix(while: WordText.prefixPunctuation.contains))
        guard !prefix.isEmpty, prefix.count < text.count,
              layouts.allSatisfy({ $0.id == source.id || source.convert(prefix, to: $0)?.contains(where: \.isLetter) != true })
        else { return nil }
        return prefix
    }

    /// A currency sign straight after the word (nsc$ → тыс$) stays as typed, like the
    /// symbols before it; the Russian layout would turn Shift-4 into %.
    var closingSymbols: String? {
        let count = text.reversed().prefix(while: WordText.closingSymbols.contains).count
        guard count > 0, count < text.count else { return nil }
        return String(text.suffix(count))
    }
}

extension Detector {
    /// Checked before input is held and before any Accessibility work. False means
    /// no correction can follow, whatever the surrounding text turns out to be.
    public func mayCorrect(_ request: CorrectionRequest) -> Bool {
        if request.isIgnored { return false }
        if let prefix = request.openingSymbols { return mayCorrect(request.with(text: String(request.text.dropFirst(prefix.count)))) }
        if let suffix = request.closingSymbols { return mayCorrect(request.with(text: String(request.text.dropLast(suffix.count)))) }
        if request.liveConverted {
            // A live-converted word only gets a spelling pass, once it is complete.
            guard !request.whileTyping, request.correctSpelling else { return false }
            return suggestSpelling(request.text, source: request.source, layouts: request.layouts,
                                   ignored: request.ignored, preferredTargetID: request.preferredTargetID) != nil
        }
        if request.whileTyping, request.paused {
            return maySuggestAfterPause(request.text, source: request.source, layouts: request.layouts, ignored: request.ignored)
        }
        return request.whileTyping
            ? maySuggestWhileTyping(request.text, source: request.source, layouts: request.layouts,
                                    ignored: request.ignored, spellingAware: request.correctSpelling)
            : maySuggestCompleted(request.text, source: request.source, layouts: request.layouts,
                                  ignored: request.ignored, correctSpelling: request.correctSpelling)
    }

    /// The replacement for the word, given up to 256 characters typed before it.
    public func correction(_ request: CorrectionRequest, context: String) -> Suggestion? {
        if request.isIgnored { return nil }
        if let prefix = request.openingSymbols {
            return correction(request.with(text: String(request.text.dropFirst(prefix.count))), context: context + prefix).map {
                Suggestion(original: request.text, replacement: prefix + $0.replacement, target: $0.target, score: $0.score)
            }
        }
        if let suffix = request.closingSymbols {
            return correction(request.with(text: String(request.text.dropLast(suffix.count))), context: context).map {
                Suggestion(original: request.text, replacement: $0.replacement + suffix, target: $0.target, score: $0.score)
            }
        }
        if request.liveConverted {
            guard !request.whileTyping, request.correctSpelling else { return nil }
            return suggestSpelling(request.text, source: request.source, layouts: request.layouts,
                                   ignored: request.ignored, preferredTargetID: request.preferredTargetID, context: context)
        }
        if request.whileTyping, request.paused {
            return suggestAfterPause(request.text, source: request.source, layouts: request.layouts, ignored: request.ignored,
                                     preferredTargetID: request.preferredTargetID, context: context)
        }
        return request.whileTyping
            ? suggestWhileTyping(request.text, source: request.source, layouts: request.layouts, ignored: request.ignored,
                                 preferredTargetID: request.preferredTargetID, context: context,
                                 spellingAware: request.correctSpelling)
            : suggestCompleted(request.text, source: request.source, layouts: request.layouts, ignored: request.ignored,
                               preferredTargetID: request.preferredTargetID, context: context,
                               correctSpelling: request.correctSpelling)
    }
}
