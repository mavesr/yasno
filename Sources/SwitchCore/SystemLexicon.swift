import AppKit

/// Morphology-aware word check through the macOS spelling service, which knows
/// inflected forms (песках, українці, aufgetretene) that a 50k frequency list
/// misses. Used only as a veto against changing valid text and as weak evidence
/// for a converted word; it never proposes text by itself. Lookups are local.
public final class SystemLexicon {
    public static let shared = SystemLexicon()

    private let lock = NSLock()
    private var cache: [String: Bool] = [:]
    private let available: Set<String>
    /// Tests and validation runs can switch the service off to isolate the dictionary rules.
    public var isEnabled = true

    private init() {
        available = Set(NSSpellChecker.shared.availableLanguages)
    }

    /// Nil when the language's spelling dictionary is not installed or the service is off.
    public func knows(_ word: String, language: Language) -> Bool? {
        guard isEnabled, available.contains(language.rawValue), !word.isEmpty, word.count <= 64 else { return nil }
        let key = language.rawValue + "\u{1}" + word
        lock.lock()
        defer { lock.unlock() }
        if let known = cache[key] { return known }
        // NSSpellChecker is not documented as thread-safe; every call stays under the lock.
        let range = NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language.rawValue,
                                                        wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        let known = range.location == NSNotFound
        if cache.count >= 100_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = known
        return known
    }

    public func knows(_ word: String, languages: [Language]) -> Bool {
        languages.contains { knows(word, language: $0) == true }
    }
}
