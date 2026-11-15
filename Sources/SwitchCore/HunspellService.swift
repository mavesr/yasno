#if !canImport(AppKit)
import Foundation
#if canImport(Glibc)
import Glibc
#endif

/// The Linux counterpart of the macOS spelling service: the distribution's Hunspell
/// dictionaries (the ones LibreOffice and Firefox use), loaded at run time. A language whose
/// dictionary is not installed is simply not offered, exactly like a missing macOS language.
final class HunspellService {
    private typealias Create = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> OpaquePointer?
    private typealias Spell = @convention(c) (OpaquePointer, UnsafePointer<CChar>) -> Int32
    private typealias Suggest = @convention(c) (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>, UnsafePointer<CChar>) -> Int32
    private typealias FreeList = @convention(c) (OpaquePointer, UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>, Int32) -> Void
    private typealias Encoding = @convention(c) (OpaquePointer) -> UnsafePointer<CChar>?

    private struct Dictionary { let handle: OpaquePointer; let encoding: String }
    private var dictionaries: [String: Dictionary] = [:]
    private var spellFn: Spell?
    private var suggestFn: Suggest?
    private var freeFn: FreeList?

    var languages: Set<String> { Set(dictionaries.keys) }

    static let directories = ["/usr/share/hunspell", "/usr/share/myspell", "/usr/share/myspell/dicts",
                              "/usr/local/share/hunspell", "/app/share/hunspell"]
    static let names: [String: [String]] = [
        "en": ["en_US", "en_GB", "en_AU", "en_CA"], "de": ["de_DE", "de_DE_frami", "de_AT", "de_CH"],
        "ru": ["ru_RU"], "uk": ["uk_UA"]]

    init() {
        guard ProcessInfo.processInfo.environment["YASNO_NO_HUNSPELL"] == nil else { return }
        var library: UnsafeMutableRawPointer?
        for name in ["libhunspell-1.7.so.0", "libhunspell-1.7.so", "libhunspell-1.6.so.0", "libhunspell.so"] {
            if let handle = dlopen(name, RTLD_NOW) { library = handle; break }
        }
        guard let library,
              let create = dlsym(library, "Hunspell_create"), let spell = dlsym(library, "Hunspell_spell"),
              let suggest = dlsym(library, "Hunspell_suggest"), let free = dlsym(library, "Hunspell_free_list"),
              let encoding = dlsym(library, "Hunspell_get_dic_encoding") else { return }
        let createFn = unsafeBitCast(create, to: Create.self)
        let encodingFn = unsafeBitCast(encoding, to: Encoding.self)
        spellFn = unsafeBitCast(spell, to: Spell.self)
        suggestFn = unsafeBitCast(suggest, to: Suggest.self)
        freeFn = unsafeBitCast(free, to: FreeList.self)
        let manager = FileManager.default
        for (language, candidates) in Self.names {
            search: for directory in Self.directories {
                for name in candidates {
                    let aff = directory + "/" + name + ".aff", dic = directory + "/" + name + ".dic"
                    guard manager.fileExists(atPath: aff), manager.fileExists(atPath: dic),
                          let handle = createFn(aff, dic) else { continue }
                    let enc = encodingFn(handle).map { String(cString: $0) } ?? "UTF-8"
                    dictionaries[language] = Dictionary(handle: handle, encoding: enc.uppercased())
                    break search
                }
            }
        }
    }

    private func encode(_ word: String, _ encoding: String) -> [CChar]? {
        if encoding == "UTF-8" || encoding == "UTF8" { return Array(word.utf8CString) }
        return Self.iconv(Array(word.utf8), from: "UTF-8", to: encoding).map { $0.map { CChar(bitPattern: $0) } + [0] }
    }

    private func decode(_ pointer: UnsafePointer<CChar>, _ encoding: String) -> String? {
        if encoding == "UTF-8" || encoding == "UTF8" { return String(validatingCString: pointer) }
        let bytes = Array(UnsafeBufferPointer(start: UnsafeRawPointer(pointer).assumingMemoryBound(to: UInt8.self), count: strlen(pointer)))
        return Self.iconv(bytes, from: encoding, to: "UTF-8").flatMap { String(bytes: $0, encoding: .utf8) }
    }

    func spell(_ word: String, language: String) -> Bool {
        guard let dictionary = dictionaries[language], let spellFn, let bytes = encode(word, dictionary.encoding) else { return false }
        return bytes.withUnsafeBufferPointer { spellFn(dictionary.handle, $0.baseAddress!) } != 0
    }

    func suggest(_ word: String, language: String) -> [String] {
        guard let dictionary = dictionaries[language], let suggestFn, let freeFn, let bytes = encode(word, dictionary.encoding) else { return [] }
        var list: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?
        let count = bytes.withUnsafeBufferPointer { suggestFn(dictionary.handle, &list, $0.baseAddress!) }
        guard count > 0, let items = list else { return [] }
        var result: [String] = []
        for index in 0..<Int(count) { if let item = items[index], let text = decode(item, dictionary.encoding) { result.append(text) } }
        freeFn(dictionary.handle, &list, count)
        return result
    }

    private static func iconv(_ input: [UInt8], from: String, to: String) -> [UInt8]? {
        let converter = iconv_open(to, from)
        guard converter != iconv_t(bitPattern: -1) else { return nil }
        defer { iconv_close(converter) }
        var source = input.map { CChar(bitPattern: $0) }
        var output = [CChar](repeating: 0, count: input.count * 4 + 8)
        let produced: Int? = source.withUnsafeMutableBufferPointer { inBuffer in
            output.withUnsafeMutableBufferPointer { outBuffer in
                var inPointer: UnsafeMutablePointer<CChar>? = inBuffer.baseAddress
                var inLeft = inBuffer.count
                var outPointer: UnsafeMutablePointer<CChar>? = outBuffer.baseAddress
                var outLeft = outBuffer.count
                guard Glibc.iconv(converter, &inPointer, &inLeft, &outPointer, &outLeft) != -1 else { return nil }
                return outBuffer.count - outLeft
            }
        }
        return produced.map { Array(output.prefix($0)).map { UInt8(bitPattern: $0) } }
    }
}
#endif
