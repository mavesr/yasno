import XCTest
import Cocoa
import Carbon
@testable import SwitchApp

final class DiagnosticTests: XCTestCase {
    var root: URL!
    var store: DiagnosticStorage!
    override func setUpWithError() throws {
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-work")
        root = work.appendingPathComponent(UUID().uuidString)
        store = try DiagnosticStorage(root: root)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }
    func start() throws {
        try store.start(repo: "owner/private-log", versions: ["yasno": "test", "macos": "test"])
    }
    func testDisabledDoesNotWrite() throws {
        XCTAssertFalse(try store.record(["text": "off"]))
        XCTAssertTrue(try store.files("sessions").isEmpty)
    }
    func testRoundTripAndPermissions() throws {
        try start()
        XCTAssertTrue(try store.record(["text": "Привет", "field": ["role": "AXTextField"]]))
        let active = try XCTUnwrap(store.active)
        let attrs = try FileManager.default.attributesOfItem(atPath: active.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.stop()
        XCTAssertFalse(try store.record(["text": "disabled"]))
        let queued = try XCTUnwrap(store.files("queue").first)
        let lines = try String(contentsOf: queued, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.count, 3)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(lines[0].utf8)) as? [String: Any])
        XCTAssertEqual((meta["versions"] as? [String: String])?["yasno"], "test")
        XCTAssertTrue(lines[1].contains("Привет"))
        XCTAssertFalse(lines.contains { $0.contains("disabled") })
    }
    func testInterruptedSessionRecoveredOnce() throws {
        try start()
        try store.record(["text": "before crash"])
        let file = try XCTUnwrap(store.active)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"partial".utf8)); try handle.close()
        let restarted = try DiagnosticStorage(root: root)
        XCTAssertEqual(try restarted.recover(), 0)
        XCTAssertEqual(try restarted.files("queue").count, 1)
        XCTAssertTrue(try restarted.files("sessions").isEmpty)
        XCTAssertEqual(try restarted.recover(), 0)
        let text = try String(contentsOf: XCTUnwrap(restarted.files("queue").first), encoding: .utf8)
        XCTAssertTrue(text.contains("interrupted"))
        XCTAssertFalse(text.contains("partial"))
    }
    func testCorruptionDoesNotBlockLaterSession() throws {
        let sessions = root.appendingPathComponent("sessions")
        try Data("{bad}\n".utf8).write(to: sessions.appendingPathComponent("000-corrupt.jsonl"))
        try start()
        try store.record(["text": "recover me"])
        let restarted = try DiagnosticStorage(root: root)
        XCTAssertEqual(try restarted.recover(), 1)
        XCTAssertEqual(try restarted.files("quarantine").count, 1)
        XCTAssertEqual(try restarted.files("queue").count, 1)
        XCTAssertTrue(try restarted.files("sessions").isEmpty)
        XCTAssertEqual(try restarted.recover(), 0)
    }
    func testInteriorCorruptionPreservesBytesAndRecoversOtherSessions() throws {
        try start()
        try store.record(["text": "keep private original"])
        let first = try XCTUnwrap(store.active)
        let handle = try FileHandle(forWritingTo: first)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("not-json\n".utf8))
        try handle.close()
        let original = try Data(contentsOf: first)
        let other = try DiagnosticStorage(root: root)
        try other.start(repo: "owner/private-log", versions: ["yasno": "test", "macos": "test"])
        try other.record(["text": "healthy session"])
        let restarted = try DiagnosticStorage(root: root)
        XCTAssertEqual(try restarted.recover(), 1)
        XCTAssertTrue(try restarted.files("sessions").isEmpty)
        let quarantined = try XCTUnwrap(restarted.files("quarantine").first)
        XCTAssertEqual(try Data(contentsOf: quarantined), original)
        let attrs = try FileManager.default.attributesOfItem(atPath: quarantined.path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try restarted.files("queue").count, 1)
        XCTAssertEqual(try restarted.recover(), 0)
    }
    func testUnreadableSessionDoesNotBlockHealthySession() throws {
        // A directory named .jsonl is deterministically unreadable as Data,
        // even when tests are run with elevated filesystem permissions.
        let unreadable = root.appendingPathComponent("sessions/000-unreadable.jsonl")
        try FileManager.default.createDirectory(at: unreadable, withIntermediateDirectories: false)
        try start()
        try store.record(["text": "recover after unreadable entry"])
        let restarted = try DiagnosticStorage(root: root)
        XCTAssertThrowsError(try restarted.recover()) { error in
            XCTAssertEqual((error as? DiagnosticError)?.localizedDescription, DiagnosticError.disk.localizedDescription)
        }
        XCTAssertEqual(try restarted.files("queue").count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))
        try FileManager.default.removeItem(at: unreadable)
        XCTAssertEqual(try restarted.recover(), 0)
    }
    func testLimitKeepsExistingRecords() throws {
        try start()
        try store.record(["text": "keep"])
        XCTAssertThrowsError(try store.record(["text": String(repeating: "x", count: 1_048_576)]))
        try store.stop()
        let text = try String(contentsOf: XCTUnwrap(store.files("queue").first), encoding: .utf8)
        XCTAssertTrue(text.contains("keep"))
        XCTAssertLessThan(text.utf8.count, 2000)
    }
    func testLimitErrorIsDistinctFromDiskError() throws {
        try start()
        XCTAssertThrowsError(try store.record(["text": String(repeating: "x", count: 1_048_576)])) { error in
            XCTAssertEqual(error as? DiagnosticError, .limit)
        }
        XCTAssertNotEqual(DiagnosticError.limit.localizedDescription, DiagnosticError.disk.localizedDescription)
        XCTAssertTrue(DiagnosticError.limit.localizedDescription.contains("заполнен"))
    }
    func testRepeatedWriteFailuresShowOneMessagePerSession() {
        let service = DiagnosticService(keychain: DiagnosticKeychain(service: "local.yasno.tests.\(UUID().uuidString)"),
                                        root: root.appendingPathComponent("service"))
        var messages: [String] = []
        service.onMessage = { messages.append($0) }
        for _ in 0..<20 { service.reportWriteFailure(DiagnosticError.limit) }
        service.reportWriteFailure(DiagnosticError.disk)
        XCTAssertEqual(messages, [DiagnosticError.limit.localizedDescription])
    }
    func testRepositoryValidation() {
        for repo in ["../private", "a/b/../../c", "https://github.com/a/b", "", "a/b?x=y"] {
            XCTAssertFalse(DiagnosticDelivery.validRepo(repo), repo)
        }
        XCTAssertTrue(DiagnosticDelivery.validRepo("mavesr/yasno-diagnostics"))
    }
    func testNearLimitCanAlwaysCloseBelowContentsThreshold() throws {
        try start()
        while (try? store.record(["text": String(repeating: "x", count: 1999)])) == true {}
        let active = try XCTUnwrap(store.active)
        let before = try Data(contentsOf: active).count
        XCTAssertGreaterThan(before, 890_000)
        try store.stop()
        let bytes = try Data(contentsOf: XCTUnwrap(store.files("queue").first))
        XCTAssertLessThanOrEqual(bytes.count, Int(DiagnosticStorage.maxSessionBytes))
        let last = try XCTUnwrap(bytes.split(separator: 10).last)
        let meta = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(last)) as? [String: Any])
        XCTAssertEqual(meta["closed_reason"] as? String, "user")
    }
    func testSkippedCountersAndTextFreeUnverifiedRecord() throws {
        try start()
        store.skip(secure: true)
        store.skip(secure: false)
        try store.record(["type": "unverified", "reason": "ax_role:-25204",
                          "app": ["bundle_id": "test.app", "name": "Test"]])
        try store.stop()
        let data = try Data(contentsOf: XCTUnwrap(store.files("queue").first))
        let rows = try data.split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
        XCTAssertEqual(rows.count, 3)
        XCTAssertEqual(rows[1]["type"] as? String, "unverified")
        XCTAssertNil(rows[1]["text"])
        XCTAssertNil(rows[1]["field"])
        XCTAssertEqual(rows[2]["events"] as? Int, 0)
        XCTAssertEqual(rows[2]["skipped_secure"] as? Int, 1)
        XCTAssertEqual(rows[2]["skipped_unverified"] as? Int, 1)
    }
    func testRealKeychainRoundTrip() throws {
        // Unique item; no production credential is accessed.
        let keychain = DiagnosticKeychain(service: "local.yasno.test.\(UUID().uuidString)")
        defer { try? keychain.save("") }
        let sentinel = UUID().uuidString + UUID().uuidString
        XCTAssertNil(try keychain.read())
        try keychain.save(sentinel)
        XCTAssertEqual(try keychain.read(), sentinel)
        try keychain.save(sentinel + "-updated")
        XCTAssertEqual(try keychain.read(), sentinel + "-updated")
        try keychain.save("")
        XCTAssertNil(try keychain.read())
    }
    func testSecretFieldsKeepTheirText() {
        for subrole in ["AXSecureTextField", "AXPasswordField", "secure", "PASSWORD"] {
            XCTAssertFalse(Diagnostics.mayRecordText(subrole: subrole, protectedStatus: .attributeUnsupported,
                                                     protected: nil, names: []), subrole)
        }
        for hint in ["Password", "pass-input", "otp-code", "api_token", "pin-code"] {
            let allowed = Diagnostics.mayRecordText(subrole: "AXTextField", protectedStatus: .attributeUnsupported,
                                                    protected: nil, names: ["editor", hint])
            XCTAssertFalse(allowed, hint)
        }
        XCTAssertFalse(Diagnostics.mayRecordText(subrole: "AXTextField", protectedStatus: .success, protected: true, names: []))
        XCTAssertFalse(Diagnostics.mayRecordText(subrole: "AXTextField", protectedStatus: .success, protected: nil, names: []))
        XCTAssertTrue(Diagnostics.mayRecordText(subrole: "AXTextField", protectedStatus: .success, protected: false, names: []))
    }
    func testUnknownSecurityStateKeepsText() {
        for error: AXError in [.cannotComplete, .apiDisabled, .invalidUIElement, .failure] {
            XCTAssertFalse(Diagnostics.mayRecordText(subrole: nil, protectedStatus: error, protected: nil, names: []))
        }
        XCTAssertTrue(Diagnostics.mayRecordText(subrole: nil, protectedStatus: .attributeUnsupported, protected: nil,
                                                names: ["AXGroup", "AXWebArea", "ProseMirror"]))
    }
    func testWordsInSecretFieldsAreRedacted() {
        let row: [String: Any] = ["text": "ghbdtn", "suffix": " ", "replacement": "привет", "pid": 42]
        let hidden = Diagnostics.redacted(row, secret: true)
        for key in ["text", "suffix", "replacement"] {
            XCTAssertEqual(hidden[key] as? String, "not recorded: field may hold a secret", key)
        }
        XCTAssertEqual(hidden["pid"] as? Int, 42)
        XCTAssertEqual(Diagnostics.redacted(row, secret: false)["text"] as? String, "ghbdtn")
    }
    func testNothingIsRecordedOutsideASession() {
        var rows: [[String: Any]] = []
        let saved = Diagnostics.sink
        Diagnostics.sink = { rows.append($0) }
        defer { Diagnostics.sink = saved; Diagnostics.setActive(false) }
        Diagnostics.setActive(false)
        Diagnostics.note("word", ["text": "ghbdtn"])
        XCTAssertTrue(rows.isEmpty)
        Diagnostics.setActive(true)
        Diagnostics.note("word", ["text": "ghbdtn"])
        guard !IsSecureEventInputEnabled() else { return }
        XCTAssertEqual(rows.first?["event"] as? String, "word")
        XCTAssertNotNil(rows.first?["uptime_ms"] as? Int)
    }
    func testWordFieldsNameTheWordAndHowItWasTyped() {
        let token = KeyboardMonitor.Token(text: "ghbdtn", suffix: " ", sourceID: "com.apple.keylayout.US", pid: 7, revision: 3)
        let fields = AppModel.diagnostic(token, live: false, ["reason": "test"])
        XCTAssertEqual(fields["text"] as? String, "ghbdtn")
        XCTAssertEqual(fields["layout"] as? String, "com.apple.keylayout.US")
        XCTAssertEqual(fields["pid"] as? Int, 7)
        XCTAssertEqual(fields["live"] as? Bool, false)
        XCTAssertEqual(fields["reason"] as? String, "test")
        XCTAssertTrue(JSONSerialization.isValidJSONObject(fields))
    }
}
