import XCTest
@testable import SwitchCore

final class LiveTypingTests: XCTestCase {
    let detector = Detector()
    let layouts = KeyboardLayout.installed(enabledOnly: false)
    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(layouts.first { $0.id == "com.apple.keylayout." + suffix })
    }

    func testReportedAddressAndOtherDomainsWithoutADictionaryWord() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        XCTAssertEqual(detector.suggest("фссщгтеюфзздуюсщь", source: ru, layouts: active)?.replacement, "account.apple.com")
        for address in ["account.apple.com", "qzx-service123.org", "example.co.uk", "unknown-brand.dev",
                        "example.museum", "example.berlin", "https://example.com/path?q=3", "example.net:8080/path",
                        "https://example.com/" + String(repeating: "a", count: 200)] {
            XCTAssertTrue(WebAddress.recognizes(address), address)
            for source in [ru, uk] {
                let input = try XCTUnwrap(abc.convert(address, to: source))
                XCTAssertTrue(detector.maySuggest(input, source: source, layouts: active), address)
                XCTAssertEqual(detector.suggest(input, source: source, layouts: active)?.replacement, address)
                XCTAssertEqual(detector.suggestWhileTyping(input, source: source, layouts: active)?.replacement, address)
                XCTAssertEqual(detector.convertTextManually(input, source: source, target: abc), address)
            }
        }
        XCTAssertEqual(detector.suggest("фссщгте.фззду.сщь", source: ru, layouts: active)?.replacement, "account.apple.com")
        XCTAssertNil(detector.suggest("фссщгтеюфзздуюсщь", source: ru, layouts: active,
            ignored: ["фссщгтеюфзздуюсщь"]))
    }

    func testDomainSyntaxRejectsCodeEmailAndMalformedHosts() throws {
        let abc = try layout("ABC"), ru = try layout("Russian")
        for input in ["foo.barDoesNotExist", "user@example.com", "foo_bar.com", "-bad.com", "bad-.com",
                      "bad..com", "x.com:0", "x.com:65536", "x.com:", "ftp://example.com", "x.com hello",
                      "index.html", "127.0.0.1", "x..", String(repeating: "a", count: 64) + ".com"] {
            XCTAssertFalse(WebAddress.recognizes(input), input)
        }
        for input in ["account.apple.com", "user@example.com", "foo_bar", "https://abc.de"] {
            XCTAssertNil(detector.suggest(input, source: abc, layouts: [abc, ru]), input)
        }
    }

    func testConfidentWordsAreSuggestedBeforeSpaceButShortPrefixesWait() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (input, output, source) in [("ghbdtn", "привет", abc), ("руддщ", "hello", ru),
                                         (",hfepth", "браузер", abc), ("фззсщттусе", "appconnect", ru)] {
            XCTAssertTrue(detector.maySuggestWhileTyping(input, source: source, layouts: active), input)
            XCTAssertEqual(detector.suggestWhileTyping(input, source: source, layouts: active,
                preferredTargetID: ru.id)?.replacement, output)
        }
        for input in ["z", "b", "f", "ns", "ghb", "API", "SwiftUI", "hello", "привет"] {
            let source = input == "привет" ? ru : abc
            XCTAssertNil(detector.suggestWhileTyping(input, source: source, layouts: active,
                preferredTargetID: ru.id), input)
        }
    }

    func testTypingSimulationKeepsContinuationAfterEarlyConversion() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let active = [abc, ru, uk]
        for (initial, intended, word) in [(abc, ru, "привет"), (ru, abc, "hello"),
                                          (ru, abc, "Github"), (uk, abc, "Github"),
                                          (abc, ru, "изучи"), (abc, ru, "изучить"), (abc, ru, "изучать"),
                                          (abc, ru, "изучите"), (abc, ru, "Изучение"),
                                          (abc, ru, "продумай"), (abc, ru, "продумайте"),
                                          (abc, ru, "переключались"), (abc, ru, "переключалась"),
                                          (ru, abc, "account.apple.com"), (uk, abc, "unknown-brand.dev")] {
            let physical = try XCTUnwrap(intended.convert(word, to: abc))
            var source = initial, rendered = "", converted = false
            for key in physical {
                rendered += try XCTUnwrap(abc.convert(String(key), to: source))
                if !converted, let result = detector.suggestWhileTyping(rendered, source: source,
                    layouts: active, preferredTargetID: ru.id) {
                    rendered = result.replacement; source = result.target; converted = true
                }
            }
            XCTAssertTrue(converted, word)
            XCTAssertEqual(rendered, word)
            XCTAssertEqual(source.id, intended.id)
        }
    }

    func testNativeDictionaryPrefixesAreNeverChangedDuringTyping() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        for (source, word) in [(abc, "information"), (abc, "browser"), (abc, "account"),
                               (ru, "приветствие"), (ru, "использовать"), (uk, "користуватися")] {
            for length in 4...word.count {
                XCTAssertNil(detector.suggestWhileTyping(String(word.prefix(length)), source: source,
                    layouts: [abc, ru, uk], preferredTargetID: ru.id), String(word.prefix(length)))
            }
        }
    }
}
