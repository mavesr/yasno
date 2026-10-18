import Foundation
import CryptoKit
import SwitchValidation

do {
    let arguments = Array(CommandLine.arguments.dropFirst())
    func value(_ name: String, fallback: String? = nil) -> String? {
        guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return fallback }
        return arguments[index + 1]
    }
    if arguments.contains("--help") {
        print("""
        YasnoValidate --profile quick|full --seed 20261018 --output PATH [--lexicon-root PATH] [--case ID] [--strict-coverage]
        YasnoValidate --suite scenarios --profile quick|full|huge --seed 20261018 --output PATH [--testdata PATH] [--case ID]
        """)
        exit(0)
    }
    let suite = value("--suite", fallback: "engine")!
    let profile = value("--profile", fallback: "quick")!
    let profiles = suite == "scenarios" ? ["quick", "full", "huge"] : ["quick", "full"]
    guard ["engine", "scenarios"].contains(suite), profiles.contains(profile),
          let seed = UInt64(value("--seed", fallback: "20261018")!) else {
        throw NSError(domain: "YasnoValidation", code: 5, userInfo: [NSLocalizedDescriptionKey: "Invalid suite, profile or seed"])
    }
    let defaultName = suite == "scenarios" ? "scenarios-\(profile)-\(seed)" : "\(profile)-\(seed)"
    let output = URL(fileURLWithPath: value("--output", fallback: ".build/validation/\(defaultName)")!, isDirectory: true)
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let completionURL = output.appendingPathComponent("complete.json")
    if FileManager.default.fileExists(atPath: completionURL.path) { try FileManager.default.removeItem(at: completionURL) }
    let failuresURL = output.appendingPathComponent("failures.jsonl")
    FileManager.default.createFile(atPath: failuresURL.path, contents: nil)
    let failures = try FileHandle(forWritingTo: failuresURL)
    defer { try? failures.close() }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
    let write: (ValidationRecord) -> Void = { record in
        if record.outcome != "passed", let data = try? encoder.encode(record) {
            failures.write(data); failures.write(Data([10]))
        }
    }
    var markdown: String
    let failed: Bool
    let reportEncoder = JSONEncoder(); reportEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if suite == "scenarios" {
        let testData = URL(fileURLWithPath: value("--testdata", fallback: ".build/testdata/prepared")!, isDirectory: true)
        let report = try ScenarioSuite(testData: testData).run(profile: profile, seed: seed, onlyCase: value("--case"), emit: write)
        try reportEncoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .atomic)
        markdown = ScenarioSummary.markdown(report)
        failed = false
    } else {
        let report = try ValidationSuite().run(profile: profile, seed: seed,
            lexiconRoot: value("--lexicon-root").map { URL(fileURLWithPath: $0) }, onlyCase: value("--case"), emit: write)
        try reportEncoder.encode(report).write(to: output.appendingPathComponent("report.json"), options: .atomic)
        markdown = "# Yasno validation\n\nProfile: \(profile); seed: \(seed); words: \(report.corpusWords).\n\n"
        markdown += "| Category | Checks | Passed | Missed | Different | Required failures |\n|---|---:|---:|---:|---:|---:|\n"
        for category in report.categories.keys.sorted() {
            let c = report.categories[category]!
            markdown += "| \(category) | \(c.total) | \(c.passed) | \(c.missed) | \(c.different) | \(c.requiredFailures) |\n"
        }
        markdown += "\nTotal: \(report.total.total); required failures: \(report.total.requiredFailures).\n\n"
        markdown += "Required gate: **\(report.total.requiredFailures == 0 ? "PASS" : "FAIL")**. Coverage: **\(report.total.passed == report.total.total ? "COMPLETE" : "OPEN — inspect misses/differences")**.\n\n"
        markdown += "Engine p50/p95/p99: \(Int(report.p50Microseconds))/\(Int(report.p95Microseconds))/\(Int(report.p99Microseconds)) µs; elapsed: \(Int(report.durationSeconds)) s.\n\n\(report.scope)\n\nAll non-passing cases are in failures.jsonl. Replay with the same seed/profile and --case ID.\n"
        failed = report.total.requiredFailures > 0 || (arguments.contains("--strict-coverage") && report.total.passed != report.total.total)
    }
    try markdown.write(to: output.appendingPathComponent("report.md"), atomically: true, encoding: .utf8)
    // Written last. An interrupted run must never compare an old summary against
    // a newly truncated failure stream and falsely report an improvement.
    func digest(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    let completion: [String: Any] = ["schema": 1, "completed": true, "files": [
        "report.json": try digest(output.appendingPathComponent("report.json")),
        "failures.jsonl": try digest(failuresURL)]]
    try JSONSerialization.data(withJSONObject: completion, options: [.prettyPrinted, .sortedKeys]).write(to: completionURL, options: .atomic)
    print(markdown)
    print("Report:", output.path)
    exit(failed ? 1 : 0)
} catch {
    fputs("Validation failed: \(error.localizedDescription)\n", stderr)
    exit(2)
}
