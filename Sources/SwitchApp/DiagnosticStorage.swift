import Foundation
import Security

enum DiagnosticError: Error, LocalizedError {
    case disk, limit, keychain, configuration, network, authorization, publicRepo, conflict
    var errorDescription: String? {
        switch self {
        case .disk: return "Не удалось записать журнал диагностики."
        case .limit: return "Журнал диагностики заполнен. Выключите диагностику, чтобы отправить его."
        case .keychain: return "Не удалось прочитать или сохранить токен в Keychain."
        case .configuration: return "Журнал сохранён на этом Mac. Чтобы отправлять его на GitHub, укажите токен и приватный репозиторий в настройках диагностики."
        case .network: return "Нет сети или GitHub недоступен. Журналы сохранены для повторной отправки."
        case .authorization:
            return "Неверный токен GitHub или нет прав на репозиторий. Журналы сохранены."
        case .publicRepo: return "Репозиторий не приватный: отправка отменена."
        case .conflict: return "Файл на GitHub отличается от локального. Журнал сохранён."
        }
    }
}

struct DiagnosticKeychain {
    var service = "local.yasno.input-diagnostics"
    var account = "github-token"
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read() throws -> String? {
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let code = SecItemCopyMatching(q as CFDictionary, &result)
        if code == errSecItemNotFound { return nil }
        guard code == errSecSuccess, let data = result as? Data,
              let token = String(data: data, encoding: .utf8) else { throw DiagnosticError.keychain }
        return token
    }
    func save(_ token: String) throws {
        if token.isEmpty {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw DiagnosticError.keychain }
            return
        }
        let data = Data(token.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var q = query
            q[kSecValueData as String] = data
            q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(q as CFDictionary, nil) == errSecSuccess else { throw DiagnosticError.keychain }
        } else if status != errSecSuccess { throw DiagnosticError.keychain }
    }
}

// Accessed exclusively on DiagnosticService.io. No secret is serialized here.
final class DiagnosticStorage {
    let root: URL
    private(set) var active: URL?
    private var count = 0
    private var skippedSecure = 0
    private var skippedUnverified = 0
    static let maxSessionBytes: UInt64 = 900_000
    // Space for closing metadata, including counters with maximum Int width.
    static let closingReserve: UInt64 = 1024
    private let fm = FileManager.default
    static func line(_ row: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys])
        data.append(10)
        return data
    }
    static var now: String { ISO8601DateFormatter().string(from: Date()) }
    init(root: URL) throws {
        self.root = root
        for name in ["", "sessions", "queue", "quarantine"] {
            let folder = root.appendingPathComponent(name)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
        }
    }
    func files(_ folder: String) throws -> [URL] {
        try fm.contentsOfDirectory(at: root.appendingPathComponent(folder),
                                   includingPropertiesForKeys: nil).filter { $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    func recover() throws -> Int {
        var corrupt = 0
        var failed = false
        for file in try files("sessions") where file != active {
            do {
                if try recover(file) { corrupt += 1 }
            } catch {
                // One unreadable file or failed quarantine must not starve
                // sessions later in the sort order. Keep the original to retry.
                failed = true
            }
        }
        if failed { throw DiagnosticError.disk }
        return corrupt
    }
    private func recover(_ file: URL) throws -> Bool {
        let data = try Data(contentsOf: file)
        let end = data.lastIndex(of: 10).map { data.index(after: $0) } ?? data.startIndex
        let prefix = Data(data[..<end])
        // Do not silently discard empty interior lines as valid JSONL.
        let rows = prefix.split(separator: 10, omittingEmptySubsequences: false).dropLast()
        let objects = rows.compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
        let id = file.deletingPathExtension().lastPathComponent
        guard !objects.isEmpty, objects.count == rows.count, objects[0]["type"] as? String == "meta",
              objects[0]["session_id"] as? String == id,
              let repo = objects[0]["target_repo"] as? String,
              repo.isEmpty || DiagnosticDelivery.validRepo(repo),
              !fm.fileExists(atPath: root.appendingPathComponent("queue/\(file.lastPathComponent)").path) else {
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            try fm.moveItem(at: file, to: root.appendingPathComponent("quarantine/\(UUID().uuidString).jsonl"))
            return true
        }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.truncate(atOffset: UInt64(prefix.count))
        try handle.seekToEnd()
        if !objects.contains(where: { $0["closed"] != nil }) {
             try handle.write(contentsOf: Self.line(["type": "meta", "closed": Self.now,
                "closed_reason": "interrupted", "events": objects.filter { $0["type"] as? String == "event" }.count,
                "skipped_secure": NSNull(),
                "skipped_unverified": objects.filter { $0["type"] as? String == "unverified" }.count,
                "skip_counters_complete": false]))
        }
        try handle.synchronize()
        try fm.moveItem(at: file, to: root.appendingPathComponent("queue/\(file.lastPathComponent)"))
        return false
    }
    func start(repo: String, versions: [String: String]) throws {
        guard active == nil else { return }
        guard try files("queue").count < 50 else { throw DiagnosticError.disk }
        let id = UUID().uuidString.lowercased()
        let file = root.appendingPathComponent("sessions/\(id).jsonl")
        let data = try Self.line(["type": "meta", "schema": 1, "session_id": id,
                                 "started": Self.now, "target_repo": repo, "versions": versions])
        guard fm.createFile(atPath: file.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw DiagnosticError.disk
        }
        active = file
        count = 0
        skippedSecure = 0
        skippedUnverified = 0
    }
    func skip(secure: Bool) {
        guard active != nil else { return }
        if secure { skippedSecure += 1 } else { skippedUnverified += 1 }
    }
    @discardableResult func record(_ row: [String: Any]) throws -> Bool {
        guard let active else { return false }
        var event = row
        event["type"] = row["type"] as? String == "unverified" ? "unverified" : "event"
        event["ts"] = Self.now
        let data = try Self.line(event)
        let handle = try FileHandle(forWritingTo: active)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size + UInt64(data.count) + Self.closingReserve <= Self.maxSessionBytes else {
            throw DiagnosticError.limit
        }
        do { try handle.write(contentsOf: data) }
        catch { try? handle.truncate(atOffset: size); throw error }
        if event["type"] as? String == "event" { count += 1 }
        return true
    }
    func stop() throws {
        guard let active else { return }
        let handle = try FileHandle(forWritingTo: active)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        do {
            try handle.write(contentsOf: Self.line(["type": "meta", "closed": Self.now,
                                                   "closed_reason": "user", "events": count,
                                                   "skipped_secure": skippedSecure,
                                                   "skipped_unverified": skippedUnverified]))
            try handle.synchronize()
            try fm.moveItem(at: active, to: root.appendingPathComponent("queue/\(active.lastPathComponent)"))
        } catch { try? handle.truncate(atOffset: size); throw error }
        self.active = nil
    }
}
