import AppKit

/// Morphology-aware word check through the macOS spelling service, which knows
/// inflected forms (песках, українці, aufgetretene) that a 50k frequency list
/// misses. Used as a veto against changing valid text, as weak evidence for a
/// converted word and to confirm a rarer dictionary correction; it never proposes
/// text by itself. Lookups are local.
public final class SystemLexicon {
    public static let shared = SystemLexicon()

    /// Guards the caches only, so cached answers never wait behind a service call.
    private let cacheLock = NSLock()
    /// NSSpellChecker is not documented as thread-safe; every call holds this lock.
    private let serviceLock = NSLock()
    private var cache: [String: Bool] = [:]
    private var guessCache: [String: [String]] = [:]
    private let available: Set<String>
    /// Tests and validation runs can switch the service off to isolate the dictionary rules.
    public var isEnabled = true

    private init() {
        available = Set(NSSpellChecker.shared.availableLanguages)
    }

    private func usable(_ word: String, _ language: Language) -> Bool {
        // The service checks each word of a string separately: им]я would pass as им + я.
        isEnabled && available.contains(language.rawValue) && word.count <= 64 && WordText.isOrthographicWord(word)
    }

    /// Nil when the language's spelling dictionary is not installed or the service is off.
    public func knows(_ word: String, language: Language) -> Bool? {
        guard usable(word, language) else { return nil }
        let key = language.rawValue + "\u{1}" + word
        cacheLock.lock()
        let cached = cache[key]
        cacheLock.unlock()
        if let cached { return cached }
        serviceLock.lock()
        let range = autoreleasepool {
            NSSpellChecker.shared.checkSpelling(of: word, startingAt: 0, language: language.rawValue,
                                                wrap: false, inSpellDocumentWithTag: 0, wordCount: nil)
        }
        serviceLock.unlock()
        let known = range.location == NSNotFound
        cacheLock.lock()
        if cache.count >= 100_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = known
        cacheLock.unlock()
        return known
    }

    /// The service's suggestions one edit away from the word, lowercased.
    public func oneEditGuesses(_ word: String, language: Language) -> [String] {
        guard usable(word, language) else { return [] }
        let key = language.rawValue + "\u{1}" + word
        cacheLock.lock()
        let cached = guessCache[key]
        cacheLock.unlock()
        if let cached { return cached }
        // Each guess call returns autoreleased objects holding a Mach port. Worker threads
        // drain their pools rarely, so without a pool per call a long run (or a long-lived
        // app) exhausts the port limit and the kernel kills the process.
        serviceLock.lock()
        let raw = autoreleasepool {
            NSSpellChecker.shared.guesses(forWordRange: NSRange(location: 0, length: (word as NSString).length), in: word,
                                          language: language.rawValue, inSpellDocumentWithTag: 0) ?? []
        }
        serviceLock.unlock()
        let lower = WordText.canonical(word.lowercased())
        var guesses: [String] = []
        for guess in raw {
            let candidate = WordText.canonical(guess.lowercased())
            if WordText.isOneEdit(lower, candidate), !guesses.contains(candidate) { guesses.append(candidate) }
        }
        cacheLock.lock()
        if guessCache.count >= 20_000 { guessCache.removeAll(keepingCapacity: true) }
        guessCache[key] = guesses
        cacheLock.unlock()
        return guesses
    }

    public func knows(_ word: String, languages: [Language]) -> Bool {
        languages.contains { knows(word, language: $0) == true }
    }
}
