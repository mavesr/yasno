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

    public init(text: String, source: KeyboardLayout, layouts: [KeyboardLayout], ignored: Set<String> = [],
                preferredTargetID: String?, correctSpelling: Bool, whileTyping: Bool, liveConverted: Bool = false) {
        self.text = text; self.source = source; self.layouts = layouts; self.ignored = ignored
        self.preferredTargetID = preferredTargetID; self.correctSpelling = correctSpelling
        self.whileTyping = whileTyping; self.liveConverted = liveConverted
    }
}

extension Detector {
    /// Checked before input is held and before any Accessibility work. False means
    /// no correction can follow, whatever the surrounding text turns out to be.
    public func mayCorrect(_ request: CorrectionRequest) -> Bool {
        if request.liveConverted {
            // A live-converted word only gets a spelling pass, once it is complete.
            guard !request.whileTyping, request.correctSpelling else { return false }
            return suggestSpelling(request.text, source: request.source, layouts: request.layouts,
                                   ignored: request.ignored, preferredTargetID: request.preferredTargetID) != nil
        }
        return request.whileTyping
            ? maySuggestWhileTyping(request.text, source: request.source, layouts: request.layouts,
                                    ignored: request.ignored, spellingAware: request.correctSpelling)
            : maySuggestCompleted(request.text, source: request.source, layouts: request.layouts,
                                  ignored: request.ignored, correctSpelling: request.correctSpelling)
    }

    /// The replacement for the word, given up to 256 characters typed before it.
    public func correction(_ request: CorrectionRequest, context: String) -> Suggestion? {
        if request.liveConverted {
            guard !request.whileTyping, request.correctSpelling else { return nil }
            return suggestSpelling(request.text, source: request.source, layouts: request.layouts,
                                   ignored: request.ignored, preferredTargetID: request.preferredTargetID, context: context)
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
