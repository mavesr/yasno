import XCTest
@testable import SwitchCore

final class CompoundWordTests: XCTestCase {
    let detector = Detector()
    let layouts = KeyboardLayout.installed(enabledOnly: false)

    func layout(_ suffix: String) throws -> KeyboardLayout {
        try XCTUnwrap(layouts.first { $0.id == "com.apple.keylayout." + suffix })
    }

    func testAppstoreRegressionAndBoundaryPreflight() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let enabled = [abc, ru, uk]
        XCTAssertEqual(ru.convert("фззыещку", to: abc), "appstore")
        XCTAssertNil(detector.rank("appstore", languages: abc.languages))
        XCTAssertTrue(detector.maySuggest("фззыещку", source: ru, layouts: enabled))
        let result = detector.suggest("фззыещку", source: ru, layouts: enabled)
        XCTAssertEqual(result?.replacement, "appstore")
        XCTAssertEqual(result?.target.id, abc.id)
    }

    func testUnlistedCompoundsFromBothCyrillicLayouts() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let enabled = [abc, ru, uk]
        for word in ["appstore", "playstore", "dropbox", "screenshot", "smartwatch", "webstore",
                     "workflow", "notepad", "checklist", "newsletter", "clouddrive"] {
            for source in [ru, uk] {
                let wrong = try XCTUnwrap(abc.convert(word, to: source))
                let result = detector.suggest(wrong, source: source, layouts: enabled, preferredTargetID: uk.id)
                XCTAssertEqual(result?.replacement, word, "\(source.name): \(wrong)")
                XCTAssertEqual(result?.target.id, abc.id, word)
            }
        }
    }

    func testCompoundCasePunctuationAndExclusion() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let enabled = [abc, ru, uk]
        for word in ["Appstore", "appstore,", "appstore!", "appstore.", "dropbox?"] {
            // Punctuation is typed as punctuation, independently of the letter layout.
            let core = word.prefix(while: \.isLetter)
            let wrong = try XCTUnwrap(abc.convert(String(core), to: ru)) + word.dropFirst(core.count)
            XCTAssertEqual(detector.suggest(wrong, source: ru, layouts: enabled)?.replacement, word)
        }
        XCTAssertNil(detector.suggest("фззыещку", source: ru, layouts: enabled, ignored: ["фззыещку"]))
        XCTAssertFalse(detector.maySuggest("фззыещку", source: ru, layouts: enabled, ignored: ["фззыещку"]))
        XCTAssertEqual(detector.convertManually("фззыещку", source: ru, layouts: enabled)?.replacement, "appstore")
    }

    func testCompoundInferenceDoesNotRewriteNativeWordsOrProtectedInput() throws {
        let abc = try layout("ABC"), ru = try layout("Russian"), uk = try layout("Ukrainian")
        let enabled = [abc, ru, uk]
        for (source, words) in [
            (ru, ["самообслуживание", "электроснабжение", "словосочетания", "приложениями", "программы", "короткими"]),
            (uk, ["самообслуговування", "електропостачання", "словосполучення", "застосунками", "програми", "короткими"]),
            (abc, ["appstore", "dropbox", "screenshot", "AppStore", "API", "SwiftUI"])
        ] {
            for word in words {
                XCTAssertNil(detector.suggest(word, source: source, layouts: enabled), word)
            }
        }
        for word in ["qzqxqz", "abcdnothing", "helloxyz", "fooapp", "appx", "appstoreextra",
                     "appstore2", "app_store", "app/store", "appstore@example.com", "APPSTORE", "AppStore"] {
            let wrong = try XCTUnwrap(abc.convert(word, to: ru))
            XCTAssertNil(detector.suggest(wrong, source: ru, layouts: enabled), word)
        }
    }
}
