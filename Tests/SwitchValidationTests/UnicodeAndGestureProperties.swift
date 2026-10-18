import XCTest
import SwitchCore
import SwitchValidation

final class UnicodeAndGestureProperties: XCTestCase {
    func testFiveThousandGraphemeAwareRangeAndBoundaryScenarios() {
        var random = ValidationRandom(seed: 0x554e49434f4445)
        let parts = ["a", "я", "і", "ї", "ё", "ß", "ü", "👩‍💻", "👨‍👩‍👧‍👦", "🇺🇦", "e\u{301}", "\r\n", "\u{202f}", " "]
        for _ in 0..<5_000 {
            let text = (0..<(1 + random.index(10))).map { _ in parts[random.index(parts.count)] }.joined()
            let indices = Array(text.indices) + [text.endIndex]
            let start = random.index(indices.count), end = start + random.index(indices.count - start)
            let expected = String(text[indices[start]..<indices[end]])
            let location = text[..<indices[start]].utf16.count
            XCTAssertEqual(TextSafety.substring(text, location: location, length: expected.utf16.count), expected)
            XCTAssertNil(TextSafety.substring(text, location: text.utf16.count + 1, length: 0))
            XCTAssertNil(TextSafety.substring(text, location: 0, length: Int.max))
            for length in 1..<"👩‍💻".utf16.count {
                XCTAssertNil(TextSafety.substring("👩‍💻" + text, location: 0, length: length))
            }
            let word = "word\(random.index(100))"
            let count = 1 + random.index(8)
            let actual = word + (0..<count).map { _ in [" ", "\u{a0}", "\u{202f}"][random.index(3)] }.joined()
            XCTAssertTrue(WordBoundary.matches(actual, word: word, suffix: String(repeating: " ", count: count)))
            XCTAssertFalse(WordBoundary.matches(actual + "\n", word: word, suffix: String(repeating: " ", count: count)))
            let last = TextSafety.lastWord(onCurrentLine: "previous\n" + word + String(repeating: " ", count: count))
            XCTAssertEqual(last?.text, word); XCTAssertEqual(last?.trailingUTF16, count)
            XCTAssertNil(TextSafety.lastWord(onCurrentLine: word + "\n   "))
        }
    }

    func testTwentyThousandIndependentGestureContractsAndRecovery() {
        var random = ValidationRandom(seed: 0x5348494654)
        for i in 0..<20_000 {
            let key: UInt16 = random.index(2) == 0 ? 56 : 60
            let kind = random.index(7)
            let start = Double(i)
            var gesture = ShiftTapGesture()
            gesture.press(key: key, at: start, clean: kind != 1)
            if kind == 2 { gesture.cancel() }
            if kind == 3 { gesture.reset() }
            if kind == 4 { gesture.press(key: key == 56 ? 60 : 56, at: start + 0.01) }
            let duration: Double = kind == 5 ? 0.6 : 0.1
            let releaseKey: UInt16 = kind == 6 ? (key == 56 ? 60 : 56) : key
            XCTAssertEqual(gesture.release(key: releaseKey, at: start + duration), kind == 0)
            XCTAssertFalse(gesture.release(key: key, at: start + duration + 0.01))
            gesture.press(key: key, at: start + 1)
            XCTAssertTrue(gesture.release(key: key, at: start + 1.1))
        }
        for bad in [Double.nan, .infinity, -.infinity] {
            var gesture = ShiftTapGesture()
            gesture.press(key: 56, at: bad)
            XCTAssertFalse(gesture.release(key: 56, at: 1))
        }
    }
}
