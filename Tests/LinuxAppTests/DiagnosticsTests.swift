import Foundation
import XCTest
import SwitchCore
@testable import YasnoLinux

final class DiagnosticsTests: XCTestCase {
    var root: URL!
    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("yasno-diagnostics-\(UUID().uuidString)")
    }
    override func tearDownWithError() throws {
        Diagnostics.setActive(false)
        Diagnostics.setSecure(false)
        try? FileManager.default.removeItem(at: root)
    }

    func rows(_ file: URL) throws -> [[String: Any]] {
        try Data(contentsOf: file).split(separator: 10).map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0)) as? [String: Any])
        }
    }

    func testJournalRoundTripIsPrivate() throws {
        let journal = try DiagnosticJournal(root: root)
        try journal.start(repo: "owner/logs", versions: ["yasno": "test"])
        try journal.record(["event": "word", "text": "ghbdtn"])
        try journal.stop(reason: "user")
        let file = try XCTUnwrap(journal.files("queue").first)
        let all = try rows(file)
        XCTAssertEqual(all.map { $0["type"] as? String }, ["meta", "event", "meta"])
        XCTAssertEqual(all[0]["platform"] as? String, "linux")
        XCTAssertEqual(all[1]["text"] as? String, "ghbdtn")
        XCTAssertEqual(all[2]["events"] as? Int, 1)
        XCTAssertEqual(journal.repo(of: file), "owner/logs")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
    }

    func testFullJournalKeepsEarlierRecords() throws {
        let journal = try DiagnosticJournal(root: root)
        try journal.start(repo: "", versions: [:])
        XCTAssertThrowsError(try journal.record(["text": String(repeating: "x", count: 1_000_000)])) {
            XCTAssertEqual($0 as? DiagnosticError, .limit)
        }
        try journal.record(["text": "ok"])
        try journal.stop(reason: "user")
        XCTAssertEqual(try rows(XCTUnwrap(journal.files("queue").first)).count, 3)
    }

    func testInterruptedSessionIsClosedAndQueued() throws {
        let first = try DiagnosticJournal(root: root)
        try first.start(repo: "", versions: [:])
        try first.record(["text": "a"])
        let active = try XCTUnwrap(first.active)
        let handle = try FileHandle(forWritingTo: active)
        try handle.seekToEnd(); try handle.write(contentsOf: Data("{\"broken".utf8)); try handle.close()
        let second = try DiagnosticJournal(root: root)
        second.recover()
        let file = try XCTUnwrap(second.files("queue").first)
        let all = try rows(file)
        XCTAssertEqual(all.count, 3)
        XCTAssertEqual(all.last?["closed_reason"] as? String, "interrupted")
    }

    func testNothingIsRecordedOutsideASessionOrDuringAPassword() {
        var rows: [[String: Any]] = []
        let saved = Diagnostics.sink
        Diagnostics.sink = { rows.append($0) }
        defer { Diagnostics.sink = saved }
        Diagnostics.note("word", ["text": "a"])
        Diagnostics.setActive(true)
        Diagnostics.setSecure(true)
        Diagnostics.note("word", ["text": "b"])
        Diagnostics.setSecure(false)
        Diagnostics.note("word", ["text": "c"])
        XCTAssertEqual(rows.map { $0["text"] as? String }, ["c"])
        XCTAssertEqual(rows.first?["event"] as? String, "word")
    }

    func testRepositoryValidation() {
        for repo in ["../private", "a/b/../../c", "https://github.com/a/b", "", "a/b?x=y", "a"] {
            XCTAssertFalse(DiagnosticDelivery.validRepo(repo), repo)
        }
        XCTAssertTrue(DiagnosticDelivery.validRepo("mavesr/yasno-diagnostics-logs"))
    }

    func testGVariantQuoting() {
        XCTAssertEqual(Desktop.quoted("it's \\ ok\nnext"), "'it\\'s \\\\ ok\\nnext'")
    }

    /// The engine writes what it decided for each word: typed, seen, corrected.
    func testEngineJournalsEachWord() {
        var rows: [[String: Any]] = []
        let lock = NSLock()
        let saved = Diagnostics.sink
        Diagnostics.sink = { row in lock.lock(); rows.append(row); lock.unlock() }
        defer { Diagnostics.sink = saved }
        let rig = TypingRig()
        rig.settings.update { $0.lastManualCyrillic = "xkb:ru" }
        Diagnostics.setActive(true)
        rig.desktop.userSelects(0)
        rig.engine.queue.sync { rig.engine.sourceChanged() }
        rig.click()
        var random = SystemRandomNumberGenerator()
        rig.type("привет как ", meaning: rig.layout("xkb:ru"), random: &random)
        rig.settle()
        Diagnostics.setActive(false)
        lock.lock(); let events = rows; lock.unlock()
        let names = events.compactMap { $0["event"] as? String }
        XCTAssertTrue(names.contains("word"), "\(names)")
        let edit = events.first { $0["event"] as? String == "edit" }
        XCTAssertEqual(edit?["result"] as? String, "success", "\(events)")
        // Corrected while typed: the edit may come before the word is finished.
        XCTAssertTrue("привет".hasPrefix(edit?["replacement"] as? String ?? "-"), "\(edit ?? [:])")
        XCTAssertEqual(rig.desktop.field.trimmingCharacters(in: .whitespaces), "привет как")
        XCTAssertTrue(events.allSatisfy { JSONSerialization.isValidJSONObject($0) })
    }

    /// The delivery script against a local fake of the GitHub contents API.
    func testDeliveryCommitsToAPrivateRepositoryOnly() throws {
        let fake = """
        import json, sys, hashlib, base64
        from http.server import BaseHTTPRequestHandler, HTTPServer
        files = {}
        private = sys.argv[1] == 'private'
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a): pass
            def reply(self, code, body):
                data = json.dumps(body).encode(); self.send_response(code)
                self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self):
                if self.headers.get('Authorization') != 'Bearer good-token-123': return self.reply(401, {})
                path = self.path.split('?')[0]
                if path == '/repos/o/r': return self.reply(200, {'private': private})
                if path in files: return self.reply(200, {'sha': files[path]})
                self.reply(404, {})
            def do_PUT(self):
                body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                data = base64.b64decode(body['content'])
                files[self.path] = hashlib.sha1(b'blob %d\\0' % len(data) + data).hexdigest()
                self.reply(201, {'commit': {'sha': 'c1'}})
        server = HTTPServer(('127.0.0.1', 0), H)
        print(server.server_port, flush=True)
        server.serve_forever()
        """
        func server(_ kind: String) throws -> (Process, Int) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "-I", "-c", fake, kind]
            let out = Pipe()
            process.standardOutput = out
            try process.run()
            var line = Data()
            while !line.contains(10) { line.append(out.fileHandleForReading.availableData) }
            return (process, Int(String(decoding: line, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))!)
        }
        let journal = try DiagnosticJournal(root: root)
        try journal.start(repo: "o/r", versions: [:])
        try journal.stop(reason: "user")
        let file = try XCTUnwrap(journal.files("queue").first)
        let saved = DiagnosticDelivery.api
        defer { DiagnosticDelivery.api = saved }

        let (open, openPort) = try server("public")
        defer { open.terminate() }
        DiagnosticDelivery.api = "http://127.0.0.1:\(openPort)"
        XCTAssertThrowsError(try DiagnosticDelivery.send(file, repo: "o/r", token: "good-token-123")) {
            XCTAssertEqual($0 as? DiagnosticError, .publicRepo)
        }

        let (closed, port) = try server("private")
        defer { closed.terminate() }
        DiagnosticDelivery.api = "http://127.0.0.1:\(port)"
        XCTAssertThrowsError(try DiagnosticDelivery.send(file, repo: "o/r", token: "wrong-token-123")) {
            XCTAssertEqual($0 as? DiagnosticError, .authorization)
        }
        XCTAssertNoThrow(try DiagnosticDelivery.send(file, repo: "o/r", token: "good-token-123"))
        // Sending again finds the same file there and succeeds without a second commit.
        XCTAssertNoThrow(try DiagnosticDelivery.send(file, repo: "o/r", token: "good-token-123"))
    }

    func testTokenIsStoredOwnerOnly() throws {
        let config = root.appendingPathComponent("config")
        let service = DiagnosticService(root: root.appendingPathComponent("journals"), configDirectory: config)
        service.save(repo: "o/r", token: "abcdefghijk123", replaceToken: true)
        let deadline = Date().addingTimeInterval(5)
        while !service.state.hasToken && Date() < deadline { usleep(10_000) }
        XCTAssertTrue(service.canSend)
        let mode = try FileManager.default.attributesOfItem(atPath: config.appendingPathComponent("diagnostic-token").path)[.posixPermissions] as? Int
        XCTAssertEqual(mode, 0o600)
        service.save(repo: "o/r", token: "", replaceToken: true)
        while service.state.hasToken && Date() < deadline { usleep(10_000) }
        XCTAssertFalse(service.state.hasToken)
    }
}
