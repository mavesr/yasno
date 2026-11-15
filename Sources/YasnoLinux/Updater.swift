import Foundation

/// Daily update from the GitHub releases of mavesr/yasno tagged linux-v…, as the Mac app does
/// with its own releases. The archive must match the SHA-256 published next to it, unpack into
/// a copy that reports the expected version, and only then replaces the installed copy.
public final class Updater {
    public struct Release: Equatable {
        public let version: String
        public let archive: URL
        public let checksum: URL?
    }

    public enum UpdateError: Error, Equatable {
        case network(String), noArchive, checksum, extraction, version, location
    }

    public static let tagPrefix = "linux-v"
    public static let checkHour = 21
    let repository: String
    let settings: Settings
    let queue = DispatchQueue(label: "yasno.update", qos: .utility)
    private var timer: DispatchSourceTimer?
    public private(set) var busy = false
    public private(set) var message = ""
    public var onChange: (() -> Void)?
    /// Called after the new copy is in place: the application restarts.
    public var onInstalled: ((URL) -> Void)?
    /// Where the running copy lives (the folder with the yasno binary).
    let installDirectory: URL?

    public init(settings: Settings, repository: String = ProcessInfo.processInfo.environment["YASNO_UPDATE_REPOSITORY"] ?? "mavesr/yasno",
                installDirectory: URL? = Updater.runningInstall()) {
        self.settings = settings; self.repository = repository; self.installDirectory = installDirectory
    }

    /// Only an installed copy updates itself (not a build run from a source tree).
    public var available: Bool { installDirectory != nil }

    public static func runningInstall() -> URL? {
        guard let executable = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/self/exe") else { return nil }
        let directory = URL(fileURLWithPath: executable).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent(".yasno-install").path),
              FileManager.default.isWritableFile(atPath: directory.deletingLastPathComponent().path) else { return nil }
        return directory
    }

    // MARK: Schedule

    public static func nextCheck(after date: Date, hour: Int = checkHour, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0, second: 0), matchingPolicy: .nextTime)
            ?? date.addingTimeInterval(86_400)
    }

    public static func missedCheck(lastCheck: Date?, now: Date, hour: Int = checkHour, calendar: Calendar = .current) -> Bool {
        let latest = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: 0, second: 0),
                                       matchingPolicy: .nextTime, direction: .backward) ?? now
        guard let lastCheck else { return true }
        return lastCheck < latest
    }

    public func schedule() {
        queue.async { [self] in
            timer?.cancel(); timer = nil
            guard available, settings.values.automaticUpdates else { return }
            let now = Date()
            let fire = Self.missedCheck(lastCheck: settings.values.lastUpdateCheck, now: now)
                ? now.addingTimeInterval(TimeInterval(ProcessInfo.processInfo.environment["YASNO_UPDATE_DELAY"] ?? "") ?? 300)
                : Self.nextCheck(after: now)
            let source = DispatchSource.makeTimerSource(queue: queue)
            source.schedule(deadline: .now() + max(fire.timeIntervalSince(now), 1), leeway: .seconds(60))
            source.setEventHandler { [weak self] in self?.check(automatic: true) }
            source.resume()
            timer = source
        }
    }

    // MARK: Check

    public func check(automatic: Bool = false) {
        queue.async { [self] in
            guard available, !busy else { return }
            busy = true; message = "Проверка обновлений…"; onChange?()
            let result: Result<Release?, UpdateError>
            do { result = .success(try latestNewer(current: YasnoVersion.current)) }
            catch let error as UpdateError { result = .failure(error) }
            catch { result = .failure(.network("\(error)")) }
            settings.update { $0.lastUpdateCheck = Date() }
            switch result {
            case .success(nil):
                busy = false; message = "Установлена последняя версия."
            case .success(let release?):
                message = "Загрузка версии \(release.version)…"; onChange?()
                do {
                    let directory = try install(release)
                    busy = false; message = "Установлена версия \(release.version). Перезапуск…"; onChange?()
                    onInstalled?(directory)
                    return
                } catch let error as UpdateError {
                    busy = false; message = Self.describe(error)
                } catch { busy = false; message = Self.describe(.network("\(error)")) }
            case .failure(let error):
                busy = false; message = automatic ? "" : Self.describe(error)
            }
            onChange?()
            schedule()
        }
    }

    public static func describe(_ error: UpdateError) -> String {
        switch error {
        case .network: return "Не удалось связаться с GitHub. Проверьте подключение к интернету."
        case .noArchive: return "В новом выпуске нет архива для этого компьютера."
        case .checksum: return "Загруженный архив не совпал с контрольной суммой и не установлен."
        case .extraction: return "Не удалось распаковать обновление."
        case .version: return "Обновление сообщило не ту версию и не установлено."
        case .location: return "Ясно запущено не из установленной копии: обновлять нечего."
        }
    }

    func latestNewer(current: String) throws -> Release? {
        // YASNO_UPDATE_FEED (a release list in GitHub's format, any URL) is for testing the update.
        let feed = ProcessInfo.processInfo.environment["YASNO_UPDATE_FEED"].flatMap(URL.init(string:))
        let data = try Download.data(feed ?? URL(string: "https://api.github.com/repos/\(repository)/releases?per_page=50")!,
                                     accept: "application/vnd.github+json")
        guard let release = try Self.parse(data, architecture: Self.architecture, anyScheme: feed != nil) else { return nil }
        return Self.isNewer(release.version, than: current) ? release : nil
    }

    public static var architecture: String {
        var info = utsname()
        uname(&info)
        let machine = withUnsafePointer(to: &info.machine) { $0.withMemoryRebound(to: CChar.self, capacity: 65) { String(cString: $0) } }
        return machine == "arm64" ? "aarch64" : machine
    }

    /// The newest published Linux release (tag linux-v<version>, not a draft or prerelease)
    /// with an archive for this architecture.
    public static func parse(_ data: Data, architecture: String, anyScheme: Bool = false) throws -> Release? {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw UpdateError.noArchive }
        var best: Release?
        for object in list {
            guard let tag = object["tag_name"] as? String, tag.hasPrefix(tagPrefix),
                  object["draft"] as? Bool != true, object["prerelease"] as? Bool != true else { continue }
            let version = String(tag.dropFirst(tagPrefix.count))
            guard components(version) != nil else { continue }
            let assets = object["assets"] as? [[String: Any]] ?? []
            func link(_ name: String) -> URL? {
                guard let asset = assets.first(where: { $0["name"] as? String == name }),
                      let text = asset["browser_download_url"] as? String, let url = URL(string: text), anyScheme || url.scheme == "https" else { return nil }
                return url
            }
            let name = "yasno-linux-\(version)-\(architecture).tar.gz"
            guard let archive = link(name) else { continue }
            let release = Release(version: version, archive: archive, checksum: link(name + ".sha256"))
            if best == nil || isNewer(version, than: best!.version) { best = release }
        }
        return best
    }

    public static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Install

    /// Returns the folder of the new copy, now in place of the old one.
    func install(_ release: Release) throws -> URL {
        guard let target = installDirectory, let checksumURL = release.checksum else { throw release.checksum == nil ? UpdateError.checksum : UpdateError.location }
        let manager = FileManager.default
        let parent = target.deletingLastPathComponent()
        let work = parent.appendingPathComponent(".update-\(release.version)")
        try? manager.removeItem(at: work)
        try manager.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: work) }
        let archive = work.appendingPathComponent("yasno.tar.gz")
        try Download.file(release.archive, to: archive)
        let expected = String(decoding: try Download.data(checksumURL), as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
        guard expected.count == 64, Checksum.sha256(file: archive) == expected.lowercased() else { throw UpdateError.checksum }
        let unpacked = work.appendingPathComponent("unpacked")
        try manager.createDirectory(at: unpacked, withIntermediateDirectories: true)
        guard Shell.run(["tar", "-xzf", archive.path, "-C", unpacked.path], timeout: 60) != nil else { throw UpdateError.extraction }
        // The archive holds one folder, yasno-linux-<version>-<arch>/, with app/ inside.
        let folder = unpacked.appendingPathComponent("yasno-linux-\(release.version)-\(Self.architecture)")
        let app = folder.appendingPathComponent("app")
        let binary = app.appendingPathComponent("yasno")
        guard manager.isExecutableFile(atPath: binary.path) else { throw UpdateError.extraction }
        guard let reported = Shell.run([binary.path, "--version"], timeout: 10)?.trimmingCharacters(in: .whitespacesAndNewlines),
              reported == release.version else { throw UpdateError.version }
        manager.createFile(atPath: app.appendingPathComponent(".yasno-install").path, contents: Data())
        let old = parent.appendingPathComponent(target.lastPathComponent + ".old")
        try? manager.removeItem(at: old)
        try manager.moveItem(at: target, to: old)
        do { try manager.moveItem(at: app, to: target) } catch {
            try? manager.moveItem(at: old, to: target)
            throw UpdateError.extraction
        }
        try? manager.removeItem(at: old)
        return target
    }
}

/// HTTPS downloads through whatever the system has: curl, wget or Python.
enum Download {
    static func data(_ url: URL, accept: String? = nil) throws -> Data {
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("yasno-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: work) }
        try file(url, to: work, accept: accept)
        return try Data(contentsOf: work)
    }

    static func file(_ url: URL, to destination: URL, accept: String? = nil) throws {
        let agent = "Yasno-Linux/\(YasnoVersion.current)"
        var attempts: [[String]] = []
        var curl = ["curl", "-fsSL", "--max-time", "120", "-A", agent, "-o", destination.path]
        if let accept { curl += ["-H", "Accept: \(accept)"] }
        attempts.append(curl + [url.absoluteString])
        var wget = ["wget", "-q", "-T", "120", "-U", agent, "-O", destination.path]
        if let accept { wget += ["--header=Accept: \(accept)"] }
        attempts.append(wget + [url.absoluteString])
        let script = """
        import sys, urllib.request
        r = urllib.request.Request(sys.argv[1], headers={'User-Agent': sys.argv[3], 'Accept': sys.argv[4]})
        open(sys.argv[2], 'wb').write(urllib.request.urlopen(r, timeout=120).read())
        """
        attempts.append(["python3", "-I", "-c", script, url.absoluteString, destination.path, agent, accept ?? "*/*"])
        for command in attempts {
            try? FileManager.default.removeItem(at: destination)
            if Shell.run(command, timeout: 180) != nil, FileManager.default.fileExists(atPath: destination.path) { return }
        }
        throw Updater.UpdateError.network(url.absoluteString)
    }
}
