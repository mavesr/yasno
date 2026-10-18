import XCTest
import SwitchCore
@testable import SwitchValidation

final class ValidationInfrastructureTests: XCTestCase {
    func testCorpusHasIndependentMultilingualVocabularyAndExplicitGoldens() throws {
        let corpus = try ValidationCorpus.load()
        XCTAssertEqual(corpus.schema, 1)
        XCTAssertEqual(Set(corpus.words.keys), ["ru", "uk", "en", "de"])
        XCTAssertGreaterThan(corpus.words.values.reduce(0) { $0 + $1.count }, 1_000)
        for words in corpus.words.values { XCTAssertEqual(words.count, Set(words).count) }
        XCTAssertTrue(corpus.strict.contains { $0[2] == "ghjlevfq" && $0[3] == "продумай" })
        XCTAssertTrue(corpus.typos.contains { $0[1] == "првиет" && $0[2] == "привет" })
    }

    func testEveryMutationClassAndStableGenerator() {
        let mutations = TypoMutation.all("hello")
        XCTAssertEqual(Set(mutations.map(\.kind)), ["omission", "duplication", "transposition", "substitution", "insertion"])
        XCTAssertTrue(mutations.contains(.init(kind: "omission", text: "helo")))
        XCTAssertTrue(mutations.contains(.init(kind: "duplication", text: "helllo")))
        XCTAssertTrue(mutations.contains(.init(kind: "transposition", text: "hlelo")))
        XCTAssertFalse(mutations.contains { $0.text == "hello" })
        XCTAssertEqual(Set(mutations.map(\.text)).count, mutations.count)
        var first = ValidationRandom(seed: 42), second = ValidationRandom(seed: 42), third = ValidationRandom(seed: 43)
        let a = (0..<100).map { _ in first.next() }, b = (0..<100).map { _ in second.next() }, c = (0..<100).map { _ in third.next() }
        XCTAssertEqual(a, b); XCTAssertNotEqual(a, c)
    }

    func testSingleCaseReplayUsesActualDetectorAndUnknownIDFails() throws {
        let suite = try ValidationSuite()
        let report = try suite.run(onlyCase: "golden/1/0/false")
        XCTAssertEqual(report.total.total, 1)
        XCTAssertEqual(report.total.passed, 1)
        XCTAssertThrowsError(try suite.run(onlyCase: "not-a-case"))
    }
}
