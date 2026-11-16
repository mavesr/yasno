import Foundation
import CYasnoLinux

/// Input diagnostics, as on the Mac (docs/diagnostics.md). While a session is on, Ясно writes
/// down what it decided for each word: the word, the layout and the application, what the
/// dictionaries said and why nothing was changed. Off by default; nothing is written while the
/// desktop reports a password entry. Linux shows Ясно no field, so the journal names the window.
public enum Diagnostics {
    private static let lock = NSLock()
    private static var on = false
    private static var secureNow = false
    /// Set once by DiagnosticService; called from any thread.
    static var sink: (([String: Any]) -> Void)?

    public static var active: Bool { lock.lock(); defer { lock.unlock() }; return on }
    static func setActive(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
    /// The desktop's own password entry has the keys (Engine.secureInput).
    static func setSecure(_ value: Bool) { lock.lock(); secureNow = value; lock.unlock() }

    /// Records one event. The fields are built only while a session is on.
    static func note(_ event: String, _ fields: @autoclosure () -> [String: Any] = [:]) {
        lock.lock(); let record = on && !secureNow; lock.unlock()
        guard record, let sink else { return }
        var row = fields()
        row["event"] = event
        row["uptime_ms"] = Int(ProcessInfo.processInfo.systemUptime * 1000)
        sink(row)
    }

    /// The word as every event about it shows it.
    static func word(_ token: WordMonitor.Token, live: Bool, _ extra: [String: Any] = [:]) -> [String: Any] {
        var fields: [String: Any] = ["text": token.text, "suffix": token.suffix, "layout": token.sourceID,
                                     "app": token.app, "live": live, "live_converted": token.liveConverted]
        fields.merge(extra) { _, new in new }
        return fields
    }
}

enum DiagnosticError: Error, Equatable {
    case disk, limit, configuration, network, authorization, publicRepo, conflict

    var message: String {
        switch self {
        case .disk: return "Не удалось записать журнал диагностики на диск."
        case .limit: return "Журнал диагностики заполнен. Выключите диагностику, чтобы сохранить его."
        case .configuration: return "Журнал сохранён на этом компьютере. Чтобы отправлять его на GitHub, укажите токен и приватный репозиторий в окне «Диагностика ввода»."
        case .network: return "Не удалось отправить журнал: нет связи с GitHub. Он остался на этом компьютере, его можно отправить позже."
        case .authorization: return "GitHub не принял токен. Проверьте, что у него есть доступ к репозиторию (Contents: Read and write)."
        case .publicRepo: return "Репозиторий открытый. Журнал отправляется только в приватный репозиторий."
        case .conflict: return "В репозитории уже есть другой файл с таким именем. Журнал остался на этом компьютере."
        }
    }
}

/// Sessions as JSON lines: sessions/<id>.jsonl while open, then queue/ until sent, then sent/
/// for a week. Owner-only permissions. Used on DiagnosticService's queue only.
final class DiagnosticJournal {
    static let maxSessionBytes = 900_000
    static let closingReserve = 1024
    let root: URL
    private(set) var active: URL?
    private var count = 0
    private let fm = FileManager.default

    static func line(_ row: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(10)
        return data
    }
    static var now: String { ISO8601DateFormatter().string(from: Date()) }

    init(root: URL) throws {
        self.root = root
        for name in ["", "sessions", "queue", "sent"] {
            let folder = root.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }

    func files(_ folder: String) -> [URL] {
        ((try? fm.contentsOfDirectory(at: root.appendingPathComponent(folder), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// A session left open when Ясно stopped is closed as interrupted and queued.
    func recover() {
        for file in files("sessions") where file != active {
            guard var data = try? Data(contentsOf: file) else { continue }
            if let end = data.lastIndex(of: 10) { data = data.prefix(through: end) } else { data = Data() }
            if let close = try? Self.line(["type": "meta", "closed": Self.now, "closed_reason": "interrupted"]) { data.append(close) }
            try? data.write(to: file)
            try? fm.moveItem(at: file, to: root.appendingPathComponent("queue/\(file.lastPathComponent)"))
        }
    }

    func start(repo: String, versions: [String: String]) throws {
        guard active == nil else { return }
        guard files("queue").count < 50 else { throw DiagnosticError.disk }
        let id = UUID().uuidString.lowercased()
        let file = root.appendingPathComponent("sessions/\(id).jsonl")
        let data = try Self.line(["type": "meta", "schema": 1, "session_id": id, "platform": "linux",
                                 "started": Self.now, "target_repo": repo, "versions": versions])
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DiagnosticError.disk
        }
        active = file
        count = 0
    }

    @discardableResult func record(_ row: [String: Any]) throws -> Bool {
        guard let active else { return false }
        var event = row
        event["type"] = "event"
        event["ts"] = Self.now
        let data = try Self.line(event)
        let handle = try FileHandle(forWritingTo: active)
        defer { try? handle.close() }
        let size = Int(try handle.seekToEnd())
        guard size + data.count + Self.closingReserve <= Self.maxSessionBytes else { throw DiagnosticError.limit }
        do { try handle.write(contentsOf: data) } catch { try? handle.truncate(atOffset: UInt64(size)); throw DiagnosticError.disk }
        count += 1
        return true
    }

    func stop(reason: String) throws {
        guard let active else { return }
        let handle = try FileHandle(forWritingTo: active)
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.line(["type": "meta", "closed": Self.now, "closed_reason": reason, "events": count]))
        try handle.synchronize()
        try handle.close()
        try fm.moveItem(at: active, to: root.appendingPathComponent("queue/\(active.lastPathComponent)"))
        self.active = nil
    }

    /// The target repository a queued journal was written for ("" when none was set).
    func repo(of file: URL) -> String? {
        guard let data = try? Data(contentsOf: file), let first = data.split(separator: 10).first,
              let meta = try? JSONSerialization.jsonObject(with: Data(first)) as? [String: Any],
              meta["type"] as? String == "meta" else { return nil }
        return meta["target_repo"] as? String ?? ""
    }

    /// A sent journal stays readable here for a week, then goes.
    func archive(_ file: URL) {
        let target = root.appendingPathComponent("sent/\(file.lastPathComponent)")
        try? fm.removeItem(at: target)
        try? fm.moveItem(at: file, to: target)
        let old = Date().addingTimeInterval(-7 * 24 * 3600)
        for item in files("sent") {
            let date = (try? fm.attributesOfItem(atPath: item.path)[.modificationDate] as? Date) ?? Date()
            if date < old { try? fm.removeItem(at: item) }
        }
    }
}

/// Commits a journal to a private GitHub repository through the system's Python (always
/// present on Ubuntu): the repository must say it is private, before and after, and the file
/// is read back at the new commit. The token goes to Python on its standard input only.
enum DiagnosticDelivery {
    static func validRepo(_ repo: String) -> Bool {
        repo.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil
            && !repo.contains("..")
    }

    static let script = """
    import sys, json, base64, hashlib, urllib.request, urllib.error
    token = sys.stdin.readline().strip()
    repo, path, name, agent, base = sys.argv[1:6]
    data = open(name, 'rb').read()
    blob = hashlib.sha1(b'blob %d\\0' % len(data) + data).hexdigest()
    def call(method, url, body=None):
        request = urllib.request.Request(base + url, method=method,
            data=None if body is None else json.dumps(body).encode(),
            headers={'Authorization': 'Bearer ' + token, 'Accept': 'application/vnd.github+json',
                     'User-Agent': agent, 'X-GitHub-Api-Version': '2022-11-28'})
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                return response.status, json.loads(response.read() or b'null')
        except urllib.error.HTTPError as error:
            try: return error.code, json.loads(error.read() or b'null')
            except Exception: return error.code, None
    def private():
        status, info = call('GET', '/repos/' + repo)
        if status in (401, 403, 404): sys.exit(11)
        if status != 200 or not isinstance(info, dict): sys.exit(13)
        if info.get('private') is not True: sys.exit(10)
    def existing(ref=None):
        status, info = call('GET', '/repos/%s/contents/%s%s' % (repo, path, '?ref=' + ref if ref else ''))
        if status == 404: return None
        if status != 200 or not isinstance(info, dict): sys.exit(13)
        return info.get('sha')
    try:
        private()
        sha = existing()
        if sha == blob: sys.exit(0)
        if sha is not None: sys.exit(12)
        private()
        status, info = call('PUT', '/repos/%s/contents/%s' % (repo, path),
            {'message': 'Diagnostic journal ' + path.split('/')[-1], 'content': base64.b64encode(data).decode()})
        if status in (401, 403): sys.exit(11)
        if status in (409, 422): sys.exit(0 if existing() == blob else 12)
        if status not in (200, 201): sys.exit(13)
        if existing(info['commit']['sha']) != blob: sys.exit(13)
    except SystemExit: raise
    except Exception: sys.exit(13)
    """

    /// Sends one journal as logs/linux/<name>. Throws the reason it stays here.
    /// Tests point it at a local fake of the GitHub API.
    static var api = "https://api.github.com"

    static func send(_ file: URL, repo: String, token: String) throws {
        guard validRepo(repo) else { throw DiagnosticError.configuration }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-I", "-c", script, repo, "logs/linux/\(file.lastPathComponent)", file.path,
                             "Yasno-Linux/\(YasnoVersion.current)", api]
        let input = Pipe()
        process.standardInput = input
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.currentDirectoryURL = URL(fileURLWithPath: "/")
        do { try process.run() } catch { throw DiagnosticError.network }
        input.fileHandleForWriting.write(Data((token + "\n").utf8))
        try? input.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(300)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        guard !process.isRunning else { process.terminate(); throw DiagnosticError.network }
        switch process.terminationStatus {
        case 0: return
        case 10: throw DiagnosticError.publicRepo
        case 11: throw DiagnosticError.authorization
        case 12: throw DiagnosticError.conflict
        default: throw DiagnosticError.network
        }
    }
}

/// One diagnostic session at a time: on from the tray or the window, off again from there or by
/// itself after half an hour. Off, the journal is closed, kept here and, when a private GitHub
/// repository and a token are set, committed there as logs/linux/<session>.jsonl.
public final class DiagnosticService {
    public static let defaultRepo = "mavesr/yasno-diagnostics-logs"
    static let sessionLimit: TimeInterval = 30 * 60

    public struct State: Equatable {
        public var enabled = false, events = 0, queued = 0, hasToken = false, busy = false
        public var repo = DiagnosticService.defaultRepo, message = ""
    }

    private let queue = DispatchQueue(label: "yasno.diagnostics", qos: .utility)
    private let lock = NSLock()
    private var current = State()
    private var journal: DiagnosticJournal?
    private var timer: DispatchSourceTimer?
    private var writeErrorShown = false
    let root: URL
    let configDirectory: URL
    /// The state changed (any thread).
    var onChange: (() -> Void)?
    /// A message the person should see now, as a desktop notification (any thread).
    var onMessage: ((String) -> Void)?
    /// State of the application at the start of a session.
    var context: (() -> [String: Any])?

    public var state: State { lock.lock(); defer { lock.unlock() }; return current }
    private func change(_ edit: (inout State) -> Void) {
        lock.lock(); edit(&current); lock.unlock()
        onChange?()
    }

    public static var defaultRoot: URL {
        let environment = ProcessInfo.processInfo.environment
        let base = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state")
        return base.appendingPathComponent("yasno/diagnostics")
    }

    public init(root: URL = DiagnosticService.defaultRoot, configDirectory: URL = Settings.configDirectory) {
        self.root = root
        self.configDirectory = configDirectory
        queue.sync {
            journal = try? DiagnosticJournal(root: root)
            journal?.recover()
            var repo = Self.defaultRepo
            if let data = try? Data(contentsOf: settingsURL),
               let saved = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["repo"] as? String { repo = saved }
            let token = readToken() != nil
            let queued = journal?.files("queue").count ?? 0
            lock.lock()
            current.repo = repo; current.hasToken = token; current.queued = queued
            if journal == nil { current.message = DiagnosticError.disk.message }
            lock.unlock()
        }
        Diagnostics.sink = { [weak self] row in self?.write(row) }
    }

    private var settingsURL: URL { configDirectory.appendingPathComponent("diagnostics.json") }
    private var tokenURL: URL { configDirectory.appendingPathComponent("diagnostic-token") }

    private func readToken() -> String? {
        guard let text = try? String(contentsOf: tokenURL, encoding: .utf8) else { return nil }
        let token = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    public var canSend: Bool { let s = state; return s.hasToken && DiagnosticDelivery.validRepo(s.repo) }

    public static let warning = "Пока диагностика включена, Ясно записывает слова, которые вы печатаете, и что оно с ними решило, а также в каком окне это было. На Linux Ясно не видит, что поле — для пароля (кроме окон входа самой системы), поэтому не вводите пароли, пока она включена. Сама выключится через 30 минут."

    private func write(_ row: [String: Any]) {
        queue.async { [self] in
            guard Diagnostics.active else { return }
            do {
                if try journal?.record(row) == true { change { $0.events += 1 } }
            } catch {
                guard !writeErrorShown else { return }
                writeErrorShown = true
                report((error as? DiagnosticError ?? .disk).message)
            }
        }
    }

    private func report(_ text: String) {
        change { $0.message = text }
        onMessage?(text)
    }

    /// Starts a session; the caller has already shown `warning` and the person agreed.
    public func start(versions: [String: String]) {
        queue.async { [self] in
            guard !state.enabled else { return }
            guard let journal else { report(DiagnosticError.disk.message); return }
            do {
                try journal.stop(reason: "restarted")
                try journal.start(repo: canSend ? state.repo : "", versions: versions)
            } catch { report((error as? DiagnosticError ?? .disk).message); return }
            writeErrorShown = false
            change { $0.enabled = true; $0.events = 0
                $0.message = "Диагностика включена. Напечатайте текст там, где Ясно не срабатывает, потом выключите её." }
            Diagnostics.setActive(true)
            Diagnostics.note("session", context?() ?? [:])
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + Self.sessionLimit)
            timer.setEventHandler { [weak self] in self?.finish(send: true, reason: "Диагностика выключилась сама через 30 минут.", why: "time limit") }
            timer.resume()
            self.timer = timer
        }
    }

    public func stop(send: Bool = true) {
        queue.async { [self] in finish(send: send, reason: nil, why: "user") }
    }

    /// Before quitting: the journal is closed and kept, sent another time.
    public func shutdown() {
        queue.sync { finish(send: false, reason: nil, why: "quit") }
    }

    private func finish(send: Bool, reason: String?, why: String) {
        guard state.enabled else { return }
        timer?.cancel(); timer = nil
        Diagnostics.setActive(false)
        do { try journal?.stop(reason: why) } catch { report(DiagnosticError.disk.message) }
        let queued = journal?.files("queue").count ?? 0
        change { $0.enabled = false; $0.queued = queued }
        guard send else { return }
        if canSend { flushNow(prefix: reason) }
        else { report([reason, "Журнал сохранён на этом компьютере (окно Ясно → «Диагностика ввода…» → «Показать журналы»)."].compactMap { $0 }.joined(separator: " ")) }
    }

    /// Sends every closed journal that is still here.
    public func flush() { queue.async { [self] in flushNow(prefix: nil) } }

    private func flushNow(prefix: String?) {
        guard let journal else { return }
        guard canSend, let token = readToken() else { report(DiagnosticError.configuration.message); return }
        let fallback = state.repo
        change { $0.busy = true; $0.message = "Отправляю журнал…" }
        var sent = 0
        var failure: DiagnosticError?
        for file in journal.files("queue") {
            let target = journal.repo(of: file).flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            do { try DiagnosticDelivery.send(file, repo: target, token: token); journal.archive(file); sent += 1 }
            catch { failure = error as? DiagnosticError ?? .network; break }
        }
        let queued = journal.files("queue").count
        change { $0.busy = false; $0.queued = queued }
        let result = failure?.message ?? (sent == 0 ? "Отправлять нечего." : "Журнал отправлен в \(fallback).")
        report([prefix, result].compactMap { $0 }.joined(separator: " "))
    }

    /// Saves the repository and, when `replaceToken`, the token (empty removes it).
    public func save(repo: String, token: String, replaceToken: Bool) {
        queue.async { [self] in
            let value = repo.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.isEmpty || DiagnosticDelivery.validRepo(value) else {
                report("Репозиторий указывается так: владелец/имя, например \(Self.defaultRepo)."); return
            }
            let fm = FileManager.default
            try? fm.createDirectory(at: configDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            if replaceToken {
                let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.isEmpty || clean.range(of: #"^[A-Za-z0-9_-]{10,255}$"#, options: .regularExpression) != nil else {
                    report("Это не похоже на токен GitHub."); return
                }
                if clean.isEmpty { try? fm.removeItem(at: tokenURL) }
                else {
                    try? fm.removeItem(at: tokenURL)
                    guard fm.createFile(atPath: tokenURL.path, contents: Data(clean.utf8), attributes: [.posixPermissions: 0o600]) else {
                        report(DiagnosticError.disk.message); return
                    }
                }
            }
            if let data = try? JSONSerialization.data(withJSONObject: ["repo": value]) { try? data.write(to: settingsURL, options: .atomic) }
            let token = readToken() != nil
            change { $0.repo = value; $0.hasToken = token
                $0.message = token && DiagnosticDelivery.validRepo(value) ? "Сохранено. Журналы будут отправляться в \(value)."
                    : "Сохранено. Журналы остаются на этом компьютере." }
        }
    }

    public var queueFolder: URL { root.appendingPathComponent("queue") }
}

/// Desktop notifications and the file manager, for messages the window may not be showing.
enum Desktop {
    /// A string in GVariant text format.
    static func quoted(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            .replacingOccurrences(of: "\n", with: "\\n") + "'"
    }

    static func notify(title: String, body: String) {
        DispatchQueue.global(qos: .utility).async {
            let args = "(\(quoted("Ясно")), uint32 0, 'yasno', \(quoted(title)), \(quoted(body)), @as [], @a{sv} {}, -1)"
            var reply = [CChar](repeating: 0, count: 256)
            _ = yl_dbus_call(0, "org.freedesktop.Notifications", "/org/freedesktop/Notifications",
                             "org.freedesktop.Notifications", "Notify", args, 2000, &reply, Int32(reply.count))
        }
    }

    static func open(_ folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["xdg-open", folder.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
