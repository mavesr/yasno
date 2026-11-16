import Cocoa
import SwiftUI

/// One diagnostic session at a time: on from the status menu, off again from there or by itself
/// after half an hour. Off, the journal is closed, kept on this Mac and, when a private GitHub
/// repository and a token are set, committed there as logs/<session>.jsonl.
final class DiagnosticService: ObservableObject {
    static let defaultRepo = "mavesr/yasno-diagnostics-logs"
    static let sessionLimit: TimeInterval = 30 * 60
    @Published private(set) var enabled = false
    @Published private(set) var events = 0
    @Published private(set) var message = ""
    @Published private(set) var hasToken = false
    @Published private(set) var queued = 0
    @Published var repo: String
    var onChange: (() -> Void)?
    var onMessage: ((String) -> Void)?
    /// State of the application at the start of a session (layouts, permissions, exclusions).
    var context: (() -> [String: Any])?
    private let io = DispatchQueue(label: "local.yasno.diagnostic-store", qos: .utility)
    private let delivery = DispatchQueue(label: "local.yasno.diagnostic-delivery", qos: .utility)
    private let keychain: DiagnosticKeychain
    private var store: DiagnosticStorage?
    private var writeErrorShown = false
    private var timer: Timer?
    let root: URL

    static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "development"
        return info?["CFBundleVersion"].map { "\(short) (\($0))" } ?? short
    }

    init(keychain: DiagnosticKeychain = DiagnosticKeychain(),
         root: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yasno/InputDiagnostics", isDirectory: true)) {
        self.keychain = keychain
        self.root = root
        repo = UserDefaults.standard.string(forKey: "diagnosticRepo") ?? Self.defaultRepo
        do {
            store = try DiagnosticStorage(root: root)
            let corrupt = try store!.recover()
            if corrupt > 0 { message = "Повреждённых журналов отложено: \(corrupt)." }
        } catch { message = DiagnosticError.disk.localizedDescription }
        hasToken = (try? keychain.read()) != nil
        countQueued()
        Diagnostics.sink = { [weak self] row in self?.write(row) }
    }

    private func write(_ row: [String: Any]) {
        io.async { [weak self] in
            guard let self, Diagnostics.active else { return }
            do {
                if try self.store?.record(row) == true {
                    DispatchQueue.main.async { if self.enabled { self.events += 1 } }
                }
            } catch {
                DispatchQueue.main.async { self.reportWriteFailure(error) }
            }
        }
    }

    /// Shows a write failure (disk error or full journal) once per session.
    func reportWriteFailure(_ error: Error) {
        guard !writeErrorShown else { return }
        writeErrorShown = true
        report(((error as? DiagnosticError) ?? .disk).localizedDescription)
    }

    func report(_ text: String) { message = text; onMessage?(text) }

    var canSend: Bool { hasToken && DiagnosticDelivery.validRepo(repo) }

    func save(token: String, replaceToken: Bool) {
        let value = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.isEmpty || DiagnosticDelivery.validRepo(value) else {
            report("Репозиторий указывается так: владелец/имя, например \(Self.defaultRepo)."); return
        }
        do {
            if replaceToken {
                let clean = token.trimmingCharacters(in: .whitespacesAndNewlines)
                guard clean.isEmpty || clean.range(of: #"^[A-Za-z0-9_-]{10,255}$"#, options: .regularExpression) != nil else {
                    report("Это не похоже на токен GitHub."); return
                }
                try keychain.save(clean)
            }
            hasToken = try keychain.read() != nil
            UserDefaults.standard.set(value, forKey: "diagnosticRepo")
            repo = value
            message = canSend ? "Сохранено. Журналы будут отправляться в \(value)." : "Сохранено. Журналы остаются на этом Mac."
        } catch { report(DiagnosticError.keychain.localizedDescription) }
    }

    func toggle() { enabled ? stop(send: true) : start() }

    func start() {
        guard !enabled else { return }
        guard let store else { report(DiagnosticError.disk.localizedDescription); return }
        let warning = NSAlert()
        warning.messageText = "Включить диагностику ввода?"
        warning.informativeText = "Пока она включена, Ясно записывает слова, которые вы печатаете, и что оно с ними решило, а также устройство поля ввода. Пароли не записываются. При выключении журнал сохраняется на этом Mac" + (canSend ? " и отправляется в приватный репозиторий \(repo)." : ".") + " Сама выключится через 30 минут."
        warning.addButton(withTitle: "Включить"); warning.addButton(withTitle: "Отмена")
        NSApp.activate(ignoringOtherApps: true)
        guard warning.runModal() == .alertFirstButtonReturn else { return }
        do {
            try io.sync {
                try store.stop()   // a session a failed stop left open is closed first
                try store.start(repo: canSend ? repo : "", versions: [
                    "yasno": Self.version, "macos": ProcessInfo.processInfo.operatingSystemVersionString])
            }
        } catch { report(DiagnosticError.disk.localizedDescription); return }
        enabled = true; events = 0; writeErrorShown = false
        Diagnostics.setActive(true)
        Diagnostics.note("session", context?() ?? [:])
        timer = Timer.scheduledTimer(withTimeInterval: Self.sessionLimit, repeats: false) { [weak self] _ in
            self?.stop(send: true, reason: "Диагностика выключилась сама через 30 минут.")
        }
        message = "Диагностика включена. Напечатайте текст в поле, где Ясно не срабатывает, потом выключите её."
        onChange?()
    }

    func stop(send: Bool, reason: String? = nil) {
        guard enabled else { return }
        timer?.invalidate(); timer = nil
        Diagnostics.setActive(false)
        enabled = false
        do { try io.sync { try store?.stop() } }
        catch { report(DiagnosticError.disk.localizedDescription) }
        countQueued()
        onChange?()
        guard send else { return }
        if canSend { flush(prefix: reason) }
        else { report([reason, "Журнал сохранён на этом Mac (Настройки диагностики → «Показать журналы»)."].compactMap { $0 }.joined(separator: " ")) }
    }

    func shutdown() { stop(send: false) }

    /// Sends every closed journal that is still on this Mac.
    func flush(prefix: String? = nil) {
        guard canSend else { report(DiagnosticError.configuration.localizedDescription); return }
        let repo = self.repo
        delivery.async { [weak self] in
            guard let self else { return }
            do {
                guard let token = try self.keychain.read() else { throw DiagnosticError.configuration }
                let files = try self.io.sync { try self.store?.files("queue") ?? [] }
                let sent = try DiagnosticDelivery().flush(files: files, token: token, fallbackRepo: repo) { file in
                    try self.io.sync { try self.archive(file) }
                }
                DispatchQueue.main.async {
                    self.countQueued()
                    self.report([prefix, sent.isEmpty ? "Отправлять нечего." : "Журнал отправлен в \(repo)."].compactMap { $0 }.joined(separator: " "))
                }
            } catch {
                let safe = (error as? DiagnosticError) ?? .network
                DispatchQueue.main.async { self.countQueued(); self.report(safe.localizedDescription) }
            }
        }
    }

    /// A sent journal stays readable on this Mac for a week, then goes.
    private func archive(_ file: URL) throws {
        let sent = root.appendingPathComponent("sent", isDirectory: true)
        try FileManager.default.createDirectory(at: sent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let target = sent.appendingPathComponent(file.lastPathComponent)
        try? FileManager.default.removeItem(at: target)
        try FileManager.default.moveItem(at: file, to: target)
        let old = Date().addingTimeInterval(-7 * 24 * 3600)
        for item in (try? FileManager.default.contentsOfDirectory(at: sent, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        where ((try? item.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()) < old {
            try? FileManager.default.removeItem(at: item)
        }
    }

    private func countQueued() {
        queued = (try? io.sync { try store?.files("queue").count }) ?? 0
    }

    func showJournals() {
        NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent("queue")])
    }
}

struct DiagnosticSettingsView: View {
    @ObservedObject var diagnostics: DiagnosticService
    @State private var token = ""
    @State private var replaceToken = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Диагностика ввода").font(.title2.bold())
            Text("Если в каком-то поле Ясно не переключает слова, включите диагностику в меню Ясно, напечатайте там несколько слов и выключите её. Журнал покажет, что Ясно увидело и почему ничего не исправило.")
                .font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Куда отправлять").font(.headline)
            TextField("Приватный репозиторий: владелец/имя", text: $diagnostics.repo).disabled(diagnostics.enabled)
            HStack {
                Text(diagnostics.hasToken ? "Токен GitHub сохранён в связке ключей." : "Токена нет: журналы остаются на этом Mac.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Toggle("Заменить токен", isOn: $replaceToken).toggleStyle(.checkbox).disabled(diagnostics.enabled)
            }
            if replaceToken {
                SecureField("Новый токен (пусто — удалить)", text: $token)
                Text("Fine-grained token на github.com → Settings → Developer settings: доступ только к этому приватному репозиторию, Contents: Read and write.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Сохранить") {
                    diagnostics.save(token: token, replaceToken: replaceToken)
                    token = ""; replaceToken = false
                }.disabled(diagnostics.enabled)
                Button("Показать журналы") { diagnostics.showJournals() }
                if diagnostics.queued > 0 && diagnostics.canSend && !diagnostics.enabled {
                    Button("Отправить (\(diagnostics.queued))") { diagnostics.flush() }
                }
                Spacer()
                if diagnostics.enabled { Text("Записей: \(diagnostics.events)").foregroundStyle(.secondary) }
            }
            if !diagnostics.message.isEmpty {
                Text(diagnostics.message).font(.caption).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }.padding(24).frame(width: 520)
    }
}
