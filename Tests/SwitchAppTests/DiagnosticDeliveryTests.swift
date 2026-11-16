import XCTest
import Foundation
@testable import SwitchApp

// Transport-level regression tests, not evidence of a live GitHub upload.
private final class DiagnosticDeliveryProtocol: URLProtocol {
    struct Exchange {
        let method: String
        let ref: String?
        let status: Int
        let object: [String: Any]
        var error: Error? = nil
        var check: ((URLRequest) throws -> Void)? = nil
    }
    final class Tape {
        private let lock = NSLock()
        private var exchanges: [Exchange]
        private var requests: [URLRequest] = []
        init(_ exchanges: [Exchange]) { self.exchanges = exchanges }
        func take(_ request: URLRequest) throws -> Exchange {
            lock.lock(); defer { lock.unlock() }
            requests.append(request)
            guard !exchanges.isEmpty else {
                XCTFail("Unexpected diagnostic HTTP request")
                throw URLError(.badServerResponse)
            }
            let exchange = exchanges.removeFirst()
            XCTAssertEqual(request.httpMethod, exchange.method)
            let ref = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "ref" })?.value
            XCTAssertEqual(ref, exchange.ref)
            try exchange.check?(request)
            return exchange
        }
        func assertFinished(file: StaticString = #filePath, line: UInt = #line) {
            lock.lock(); defer { lock.unlock() }
            XCTAssertTrue(exchanges.isEmpty, "Missing diagnostic HTTP requests", file: file, line: line)
        }
    }
    private static let lock = NSLock()
    private static var tapes: [String: Tape] = [:]
    static func register(_ tape: Tape, id: String) {
        lock.lock(); defer { lock.unlock() }; tapes[id] = tape
    }
    static func remove(_ id: String) {
        lock.lock(); defer { lock.unlock() }; tapes.removeValue(forKey: id)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let tape = Self.tapes[request.value(forHTTPHeaderField: "X-Yasno-Test-ID") ?? ""]
        Self.lock.unlock()
        do {
            let exchange = try XCTUnwrap(tape).take(request)
            if let error = exchange.error { throw error }
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: exchange.status,
                httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: try JSONSerialization.data(withJSONObject: exchange.object))
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

final class DiagnosticDeliveryTests: XCTestCase {
    private var root: URL!
    private var store: DiagnosticStorage!
    private var file: URL!
    private var original: Data!
    private let commit = String(repeating: "a", count: 40)
    private let branch = "diagnostics/test branch"
    override func setUpWithError() throws {
        let work = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".test-work")
        root = work.appendingPathComponent(UUID().uuidString)
        store = try DiagnosticStorage(root: root)
        try store.start(repo: "owner/private-log", versions: ["yasno": "test", "macos": "test"])
        try store.record(["text": "delivery fixture", "source": "integration_fixture"])
        try store.stop()
        file = try XCTUnwrap(store.files("queue").first)
        original = try Data(contentsOf: file)
    }
    override func tearDownWithError() throws {
        if let root { try FileManager.default.removeItem(at: root) }
    }
    private var metadata: DiagnosticDeliveryProtocol.Exchange {
        .init(method: "GET", ref: nil, status: 200, object: ["private": true, "default_branch": branch])
    }
    private var missing: DiagnosticDeliveryProtocol.Exchange {
        .init(method: "GET", ref: branch, status: 404, object: [:])
    }
    private func content(_ data: Data) -> [String: Any] {
        ["content": data.base64EncodedString(), "sha": DiagnosticDelivery.blobSHA(data),
         "encoding": "base64", "type": "file"]
    }
    private func body(_ request: URLRequest) throws -> [String: Any] {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                let size = stream.read(&buffer, maxLength: buffer.count)
                if size == 0 { break }
                guard size > 0 else { throw URLError(.cannotDecodeContentData) }
                data.append(contentsOf: buffer.prefix(size))
            }
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
    private var created: DiagnosticDeliveryProtocol.Exchange {
        .init(method: "PUT", ref: nil, status: 201, object: ["commit": ["sha": commit]], check: { request in
            let payload = try self.body(request)
            XCTAssertEqual(payload["branch"] as? String, self.branch)
            XCTAssertEqual(payload["content"] as? String, self.original.base64EncodedString())
            XCTAssertEqual(request.url?.path, "/repos/owner/private-log/contents/logs/\(self.file.lastPathComponent)")
        })
    }
    private func deliver(_ steps: [DiagnosticDeliveryProtocol.Exchange], expected: DiagnosticError? = nil,
                         prependUnreadable: Bool = false) throws {
        let id = UUID().uuidString
        let tape = DiagnosticDeliveryProtocol.Tape(steps)
        DiagnosticDeliveryProtocol.register(tape, id: id)
        defer { DiagnosticDeliveryProtocol.remove(id) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [DiagnosticDeliveryProtocol.self]
        config.httpAdditionalHeaders = ["X-Yasno-Test-ID": id]
        let delivery = DiagnosticDelivery(configuration: config)
        if prependUnreadable {
            let bad = root.appendingPathComponent("missing.jsonl")
            XCTAssertThrowsError(try delivery.flush(files: [bad, file], token: "test-not-a-credential", fallbackRepo: "") {
                try FileManager.default.removeItem(at: $0)
            })
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        } else if let expected {
            XCTAssertThrowsError(try delivery.flush(store: store, token: "test-not-a-credential")) { error in
                XCTAssertEqual((error as? DiagnosticError)?.localizedDescription, expected.localizedDescription)
            }
            XCTAssertEqual(try Data(contentsOf: file), original)
        } else {
            XCTAssertEqual(try delivery.flush(store: store, token: "test-not-a-credential").count, 1)
            XCTAssertFalse(FileManager.default.fileExists(atPath: file.path))
        }
        tape.assertFinished()
    }
    func testReadBackExactCommitBeforeDeletingQueue() throws {
        try deliver([metadata, missing, metadata, created,
            .init(method: "GET", ref: commit, status: 200, object: content(original))])
    }
    func testReadBackMismatchKeepsQueue() throws {
        try deliver([metadata, missing, metadata, created,
            .init(method: "GET", ref: commit, status: 200, object: content(Data("different".utf8)))],
            expected: .conflict)
    }
    func testLostReadBackConnectionKeepsQueue() throws {
        try deliver([metadata, missing, metadata, created,
            .init(method: "GET", ref: commit, status: 0, object: [:], error: URLError(.networkConnectionLost))],
            expected: .network)
    }
    func testAuthorizationFailureKeepsQueue() throws {
        try deliver([.init(method: "GET", ref: nil, status: 401, object: [:])], expected: .authorization)
    }
    func testPublicRepositoryNeverReceivesJournal() throws {
        try deliver([.init(method: "GET", ref: nil, status: 200,
                           object: ["private": false, "default_branch": branch])], expected: .publicRepo)
    }
    func testIdempotentRetryDoesNotPutAgain() throws {
        try deliver([metadata, .init(method: "GET", ref: branch, status: 200, object: content(original))])
    }
    func testDifferentExistingFileKeepsQueue() throws {
        try deliver([metadata, .init(method: "GET", ref: branch, status: 200,
                                   object: content(Data("different".utf8)))], expected: .conflict)
    }
    func testBlobHashKnownGitVector() {
        XCTAssertEqual(DiagnosticDelivery.blobSHA(Data()), "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        XCTAssertEqual(DiagnosticDelivery.blobSHA(Data("hello\n".utf8)),
                       "ce013625030ba8dba906f756967f9e9ca394464a")
    }
    func testLargeExistingBlobWithoutContentIsVerified() throws {
        original = Data(repeating: 120, count: 1_048_577)
        try original.write(to: file)
        // flush requires the session header, so exercise push directly using
        // the same transport via a normal queue containing a large event.
        let header = try DiagnosticStorage.line(["type": "meta", "target_repo": "owner/private-log"])
        original = header + original
        try original.write(to: file)
        try deliver([metadata, .init(method: "GET", ref: branch, status: 200,
            object: ["sha": DiagnosticDelivery.blobSHA(original), "encoding": "none", "content": ""])])
    }
    func testBadFileDoesNotStarveLaterDelivery() throws {
        try deliver([metadata, .init(method: "GET", ref: branch, status: 200,
            object: ["sha": DiagnosticDelivery.blobSHA(original)])], prependUnreadable: true)
    }
    func testPutReadBackUsesBlobSHAWithoutContent() throws {
        try deliver([metadata, missing, metadata, created,
            .init(method: "GET", ref: commit, status: 200,
                  object: ["sha": DiagnosticDelivery.blobSHA(original), "encoding": "none"])])
    }
}
