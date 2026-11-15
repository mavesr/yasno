import Foundation
import XCTest
import SwitchCore
@testable import YasnoLinux

/// End-to-end typing through the Linux engine: keys go through the input hub and the word
/// monitor, corrections are typed back on the (fake) virtual keyboard, and the field shows
/// what the desktop would show.
final class TypingTests: XCTestCase {
    static let russian = [
        "привет как у тебя дела", "сегодня очень хорошая погода", "я написал письмо своему другу",
        "мы поедем на дачу в субботу", "спасибо за помощь с проектом", "давай встретимся завтра вечером",
        "это была отличная идея", "позвони мне когда освободишься", "они купили новую машину",
        "надо закончить отчёт до пятницы", "где находится ближайшая аптека", "книга лежит на столе",
    ]
    static let ukrainian = [
        "привіт як у тебе справи", "сьогодні дуже гарна погода", "дякую за допомогу з проєктом",
        "ми поїдемо до моря влітку", "давай зустрінемося завтра ввечері", "це була чудова ідея",
        "де знаходиться найближча аптека", "книжка лежить на столі", "я прочитав цікаву статтю",
    ]
    static let english = [
        "hello how are you today", "the weather is really nice", "thank you for your help with the project",
        "we will meet tomorrow evening", "please send me the report", "this was a great idea",
        "where is the nearest pharmacy", "the book is on the table",
    ]
    static let german = [
        "guten morgen wie geht es dir", "das wetter ist heute sehr schön", "vielen dank für deine hilfe",
        "wir treffen uns morgen abend", "das war eine gute idee",
    ]

    struct Score { var fixed = 0, kept = 0, garbled: [String] = [] }

    /// Each word must end up either as meant or exactly as typed in the wrong layout: never mixed.
    func score(field: String, meant: String, raw: String) -> Score {
        var score = Score()
        let got = field.split(separator: " ").map(String.init)
        let want = meant.split(separator: " ").map(String.init)
        let wrong = raw.split(separator: " ").map(String.init)
        guard got.count == want.count else { score.garbled.append("«\(field)» ≠ «\(meant)»"); return score }
        for (index, word) in got.enumerated() {
            if word == want[index] { score.fixed += 1 } else if word == wrong[index] { score.kept += 1 }
            else { score.garbled.append("\(word) (\(want[index]))") }
        }
        return score
    }

    func run(_ sentences: [String], meaning meantID: String, startingIn startID: String, gap: ClosedRange<Double> = 0.03...0.06,
             layouts: [(String, String)] = [("us", ""), ("ru", ""), ("ua", "")]) -> (Score, [String]) {
        let rig = TypingRig(layouts: layouts)
        // The user's Cyrillic layout, as the Mac app learns it from the first manual switch.
        if meantID == "xkb:ru" || meantID == "xkb:ua" { rig.settings.update { $0.lastManualCyrillic = meantID } }
        var random = SystemRandomNumberGenerator()
        var total = Score()
        var failures: [String] = []
        for sentence in sentences {
            rig.desktop.clear()
            rig.desktop.userSelects(rig.desktop.specs.firstIndex { $0.id == startID }!)
            rig.engine.queue.sync { rig.engine.sourceChanged() }
            rig.click() // a new field
            let meant = rig.layout(meantID), start = rig.layout(startID)
            rig.type(sentence + " ", meaning: meant, gap: gap, random: &random)
            rig.settle()
            let raw = meant.convert(sentence, to: start) ?? sentence
            let field = rig.desktop.field.trimmingCharacters(in: .whitespaces)
            let s = score(field: field, meant: sentence, raw: raw)
            total.fixed += s.fixed; total.kept += s.kept; total.garbled += s.garbled
            if field != sentence { failures.append("«\(field)» ← «\(sentence)»") }
        }
        return (total, failures)
    }

    func testRussianTypedOnEnglishLayoutIsFixed() {
        let (score, failures) = run(Self.russian, meaning: "xkb:ru", startingIn: "xkb:us")
        print("ru on us: fixed \(score.fixed) kept \(score.kept) garbled \(score.garbled.count)\n  " + failures.joined(separator: "\n  "))
        XCTAssertEqual(score.garbled, [])
        XCTAssertGreaterThanOrEqual(Double(score.fixed) / Double(score.fixed + score.kept), 0.95)
    }

    func testUkrainianTypedOnEnglishLayoutIsFixed() {
        let (score, failures) = run(Self.ukrainian, meaning: "xkb:ua", startingIn: "xkb:us")
        print("uk on us: fixed \(score.fixed) kept \(score.kept) garbled \(score.garbled.count)\n  " + failures.joined(separator: "\n  "))
        XCTAssertEqual(score.garbled, [])
        XCTAssertGreaterThanOrEqual(Double(score.fixed) / Double(score.fixed + score.kept), 0.9)
    }

    func testEnglishTypedOnRussianLayoutIsFixed() {
        let (score, failures) = run(Self.english, meaning: "xkb:us", startingIn: "xkb:ru")
        print("en on ru: fixed \(score.fixed) kept \(score.kept) garbled \(score.garbled.count)\n  " + failures.joined(separator: "\n  "))
        XCTAssertEqual(score.garbled, [])
        XCTAssertGreaterThanOrEqual(Double(score.fixed) / Double(score.fixed + score.kept), 0.95)
    }

    func testGermanTypedOnRussianLayoutIsFixed() {
        let (score, failures) = run(Self.german, meaning: "xkb:de", startingIn: "xkb:ru",
                                    layouts: [("de", ""), ("ru", "")])
        print("de on ru: fixed \(score.fixed) kept \(score.kept) garbled \(score.garbled.count)\n  " + failures.joined(separator: "\n  "))
        XCTAssertEqual(score.garbled, [])
        XCTAssertGreaterThanOrEqual(Double(score.fixed) / Double(score.fixed + score.kept), 0.9)
    }

    func testCorrectTextIsNeverChanged() {
        for (sentences, id) in [(Self.russian, "xkb:ru"), (Self.ukrainian, "xkb:ua"), (Self.english, "xkb:us")] {
            let (score, failures) = run(sentences, meaning: id, startingIn: id)
            XCTAssertEqual(failures, [], id)
            XCTAssertEqual(score.kept + score.garbled.count, 0, id)
        }
    }

    /// Fast typing: the next keys arrive while a correction is being typed and wait for it.
    func testFastTypingKeepsEveryKeyInOrder() {
        let (score, failures) = run(Self.russian, meaning: "xkb:ru", startingIn: "xkb:us", gap: 0.004...0.012)
        print("fast ru on us: fixed \(score.fixed) kept \(score.kept) garbled \(score.garbled.count)\n  " + failures.joined(separator: "\n  "))
        XCTAssertEqual(score.garbled, [])
    }

    func testShiftConvertsTheLastWordAndShiftAgainCycles() {
        let rig = TypingRig()
        var random = SystemRandomNumberGenerator()
        rig.engine.queue.sync { rig.engine.apply(allowed: true) }
        // A word the detector leaves alone is converted by a short Shift.
        rig.type("ok", meaning: rig.layout("xkb:us"), random: &random)
        rig.sleep(0.05)
        rig.tapShift()
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "щл")
        // Ukrainian types the same letters here: the layout changes, the text stays.
        rig.tapShift()
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "щл")
        XCTAssertEqual(rig.desktop.currentIndex(), 2)
        rig.tapShift()
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "ok")
        XCTAssertEqual(rig.desktop.currentIndex(), 0)
    }

    func testShiftAfterAutomaticCorrectionUndoesIt() {
        let rig = TypingRig()
        var random = SystemRandomNumberGenerator()
        rig.type("ghbdtn ", meaning: rig.layout("xkb:us"), random: &random)
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "привет ")
        rig.tapShift()
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "ghbdtn ")
        XCTAssertEqual(rig.desktop.currentIndex(), 0)
    }

    func testShiftInAnEmptyFieldSwitchesLayout() {
        let rig = TypingRig()
        rig.click()
        rig.tapShift()
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "")
        XCTAssertEqual(rig.desktop.currentIndex(), 1)
    }

    func testUppercaseAndCapsLock() {
        let rig = TypingRig()
        var random = SystemRandomNumberGenerator()
        rig.type("Ghbdtn ", meaning: rig.layout("xkb:us"), random: &random)
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "Привет ")
    }

    func testFailedLayoutSwitchLeavesTheWordAsTyped() {
        let rig = TypingRig()
        var random = SystemRandomNumberGenerator()
        rig.desktop.failSelect = true
        rig.type("ghbdtn rfr ltkf ", meaning: rig.layout("xkb:us"), random: &random)
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "ghbdtn rfr ltkf ")
    }

    func testExcludedApplicationIsLeftAlone() {
        let rig = TypingRig()
        var random = SystemRandomNumberGenerator()
        rig.desktop.app = "org.gnome.Terminal.desktop"
        rig.engine.queue.sync { rig.engine.refreshApp(); rig.engine.apply(allowed: true) }
        rig.type("ghbdtn ", meaning: rig.layout("xkb:us"), random: &random)
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "ghbdtn ")
    }

    /// Leaving an excluded application and typing at once: the first word is already judged in
    /// the new application, before the periodic refresh has noticed the switch.
    func testWordRightAfterLeavingExcludedApplication() {
        let rig = TypingRig()
        var random = SystemRandomNumberGenerator()
        rig.desktop.app = "org.gnome.Terminal.desktop"
        rig.engine.queue.sync { rig.engine.refreshApp(); rig.engine.apply(allowed: true) }
        rig.type("ghbdtn ", meaning: rig.layout("xkb:us"), random: &random)
        rig.settle()
        rig.desktop.clear()
        rig.desktop.app = "org.gnome.TextEditor.desktop"
        rig.type("ghbdtn vbh ", meaning: rig.layout("xkb:us"), random: &random)
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "привет мир ")
    }

    func testPausedEngineForwardsEverything() {
        let rig = TypingRig()
        var random = SystemRandomNumberGenerator()
        rig.settings.update { $0.enabled = false }
        rig.engine.queue.sync { rig.engine.apply(allowed: true) }
        rig.type("ghbdtn ", meaning: rig.layout("xkb:us"), random: &random)
        rig.settle()
        XCTAssertEqual(rig.desktop.field, "ghbdtn ")
    }

    /// The engine never answering must not keep the keyboard: held keys go out after a second.
    func testStalledEngineReleasesHeldKeys() {
        let rig = TypingRig()
        var random = SystemRandomNumberGenerator()
        rig.engine.queue.suspend()
        rig.type("ghbdtn ", meaning: rig.layout("xkb:us"), random: &random)
        rig.type("vbh", meaning: rig.layout("xkb:us"), random: &random)
        // Keys after the Space are held for the reserved boundary until the watchdog lets go.
        rig.sleep(1.2)
        rig.hub.tick()
        XCTAssertEqual(rig.desktop.field, "ghbdtn vbh")
        rig.engine.queue.resume()
        rig.settle()
    }
}
