import Foundation

/// Syntax recognition only. Never resolves a hostname or contacts a website.
public enum WebAddress {
    private static let topLevelDomains: Set<String> = {
        guard let url = Bundle.module.url(forResource: "tlds-alpha-by-domain", withExtension: "txt", subdirectory: "Resources"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return Set(text.split(separator: "\n").filter { !$0.hasPrefix("#") }.map { $0.lowercased() })
    }()

    public static func recognizes(_ text: String) -> Bool {
        guard (4...512).contains(text.utf8.count), !text.contains(where: \.isWhitespace),
              !text.contains("@"), text.utf8.allSatisfy({ $0 > 32 && $0 < 127 }) else { return false }
        let lower = text.lowercased()
        let address: String
        if lower.hasPrefix("https://") { address = String(text.dropFirst(8)) }
        else if lower.hasPrefix("http://") { address = String(text.dropFirst(7)) }
        else if lower.contains("://") { return false }
        else { address = text }
        let authority = String(address.prefix(while: { !"/?#".contains($0) }))
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count) else { return false }
        if parts.count == 2 {
            guard !parts[1].isEmpty, parts[1].allSatisfy(\.isNumber),
                  let port = Int(parts[1]), (1...65_535).contains(port) else { return false }
        }
        let host = String(parts[0]).lowercased()
        guard host.utf8.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, let last = labels.last, topLevelDomains.contains(String(last)) else { return false }
        return labels.allSatisfy { label in
            (1...63).contains(label.utf8.count) && label.first != "-" && label.last != "-" &&
                label.utf8.allSatisfy { (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }
        }
    }

    static func converted(_ text: String, source: KeyboardLayout, target: KeyboardLayout) -> String? {
        guard source.languages.contains(where: { $0 == .russian || $0 == .ukrainian }),
              target.languages.contains(where: { $0 == .english || $0 == .german }),
              text.unicodeScalars.contains(where: { (0x400...0x4ff).contains($0.value) }) else { return nil }
        // Both physical punctuation (ю → .) and deliberately typed literal dots occur.
        for preserve in [false, true] {
            if let output = source.convert(text, to: target, preservingPunctuation: preserve), recognizes(output) {
                return output
            }
        }
        return nil
    }
}
