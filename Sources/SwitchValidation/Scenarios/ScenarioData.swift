import Foundation
import CryptoKit

/// Real sentences and real misspellings prepared by scripts/fetch-testdata.py.
struct ScenarioData {
    struct Sentence {
        let source: String
        let mixedScript: Bool
        let text: String
        /// Misspellings annotated in the treebank, typed form → correct form.
        let typos: [(typed: String, correct: String)]
    }

    struct TypoPair {
        let typed: String
        let correct: String
        let source: String
    }

    let sentences: [String: [Sentence]]
    let typos: [String: [TypoPair]]
    let fingerprint: String

    static let languages = ["ru", "uk", "en", "de"]

    static func load(_ directory: URL) throws -> ScenarioData {
        var sentences: [String: [Sentence]] = [:], typos: [String: [TypoPair]] = [:]
        var hasher = SHA256()
        func lines(_ name: String) throws -> [Substring] {
            let url = directory.appendingPathComponent(name)
            guard let data = FileManager.default.contents(atPath: url.path),
                  let text = String(data: data, encoding: .utf8) else {
                throw NSError(domain: "YasnoValidation", code: 6, userInfo: [NSLocalizedDescriptionKey:
                    "Missing \(url.path). Run: python3 scripts/fetch-testdata.py"])
            }
            hasher.update(data: Data(name.utf8)); hasher.update(data: data)
            return text.split(separator: "\n")
        }
        for language in languages {
            sentences[language] = try lines("sentences-\(language).tsv").compactMap { line in
                let columns = line.split(separator: "\t", omittingEmptySubsequences: false)
                guard columns.count >= 3 else { return nil }
                let pairs = columns.count > 3 ? columns[3].split(separator: ";").compactMap { pair -> (typed: String, correct: String)? in
                    let parts = pair.split(separator: ">", maxSplits: 1)
                    return parts.count == 2 ? (String(parts[0]), String(parts[1])) : nil
                } : []
                return Sentence(source: String(columns[0]), mixedScript: columns[1] == "m",
                                text: String(columns[2]), typos: pairs)
            }
            typos[language] = try lines("typos-\(language).tsv").compactMap { line in
                let columns = line.split(separator: "\t")
                guard columns.count >= 4 else { return nil }
                return TypoPair(typed: String(columns[0]), correct: String(columns[1]), source: String(columns[3]))
            }
        }
        let fingerprint = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return ScenarioData(sentences: sentences, typos: typos, fingerprint: fingerprint)
    }
}
