import Cocoa
import Security
import os

/// Daily update from GitHub Releases for the website (Developer ID) edition.
///
/// macOS keeps the Accessibility and Input Monitoring grants for a new build only when it
/// satisfies the designated requirement recorded for the old one (same Team ID and bundle
/// identifier). So a download is installed only if it satisfies the designated requirement
/// of the running copy, is notarized, and replaces the bundle in place at the same path.
/// Anything else (a development build, a moved or translocated copy)
/// leaves the installed application untouched.
@MainActor final class Updater: ObservableObject {
    struct Release: Equatable {
        let version: String
        let archive: URL
    }

    enum UpdateError: Error, Equatable {
        case network(String)
        case noArchive
        case extraction
        case signature(String)
        case version
        case location
    }

    @Published var automatic: Bool {
        didSet { UserDefaults.standard.set(automatic, forKey: "automaticUpdates"); schedule() }
    }
    @Published private(set) var busy = false
    @Published private(set) var message = ""

    /// "owner/name" of the public repository with release archives; nil disables updates.
    let repository: String?
    nonisolated static let checkHour = 21
    private let log = Logger(subsystem: "local.yasno.switcher", category: "update")
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Called on main after the new copy is in place; the application quits and is reopened.
    var onInstalled: (() -> Void)?

    init(bundle: Bundle = .main) {
        automatic = UserDefaults.standard.object(forKey: "automaticUpdates") as? Bool ?? true
        repository = Self.repository(info: bundle.infoDictionary ?? [:])
        guard repository != nil else { return }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.schedule() } }
        schedule()
    }

    var available: Bool { repository != nil }

    // MARK: Schedule

    nonisolated static func repository(info: [String: Any]) -> String? {
        guard let value = info["YasnoUpdateRepository"] as? String else { return nil }
        let parts = value.split(separator: "/")
        return parts.count == 2 && parts.allSatisfy({ !$0.isEmpty }) ? value : nil
    }

    /// The first `hour`:00 strictly after `date`.
    nonisolated static func nextCheck(after date: Date, hour: Int = checkHour, calendar: Calendar = .current) -> Date {
        calendar.nextDate(after: date, matching: DateComponents(hour: hour, minute: 0, second: 0),
                          matchingPolicy: .nextTime) ?? date.addingTimeInterval(86_400)
    }

    /// Whether a check at `hour`:00 was missed (the Mac slept or the application was not running).
    nonisolated static func missedCheck(lastCheck: Date?, now: Date, hour: Int = checkHour, calendar: Calendar = .current) -> Bool {
        let latest = calendar.nextDate(after: now, matching: DateComponents(hour: hour, minute: 0, second: 0),
                                       matchingPolicy: .nextTime, direction: .backward) ?? now
        guard let lastCheck else { return true }
        return lastCheck < latest
    }

    private func schedule() {
        timer?.invalidate(); timer = nil
        guard available, automatic else { return }
        let now = Date()
        let last = UserDefaults.standard.object(forKey: "lastUpdateCheck") as? Date
        // A missed 21:00 is caught up a few minutes after launch or wake, once the network is up.
        let fire = Self.missedCheck(lastCheck: last, now: now) ? now.addingTimeInterval(300) : Self.nextCheck(after: now)
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in MainActor.assumeIsolated { self?.check(automatic: true) } }
        timer.tolerance = 60
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: Check

    func check(automatic: Bool = false) {
        guard let repository, !busy else { return }
        busy = true
        message = "Проверка обновлений…"
        Task { [weak self] in
            let result: Result<Release?, UpdateError>
            do { result = .success(try await Self.latestNewer(repository: repository, current: Self.currentVersion)) }
            catch let error as UpdateError { result = .failure(error) }
            catch { result = .failure(.network(error.localizedDescription)) }
            self?.finishCheck(result, automatic: automatic)
        }
    }

    private func finishCheck(_ result: Result<Release?, UpdateError>, automatic: Bool) {
        UserDefaults.standard.set(Date(), forKey: "lastUpdateCheck")
        switch result {
        case .success(nil):
            busy = false
            message = "Установлена последняя версия."
            schedule()
        case .success(let release?):
            message = "Загрузка версии \(release.version)…"
            install(release)
        case .failure(let error):
            busy = false
            log.error("Update check failed: \(String(describing: error), privacy: .public)")
            message = automatic ? "" : Self.describe(error)
            schedule()
        }
    }

    nonisolated static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    nonisolated static func latestNewer(repository: String, current: String) async throws -> Release? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Yasno/\(current)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        // 404 means no published release yet.
        if (response as? HTTPURLResponse)?.statusCode == 404 { return nil }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        guard let release = try parse(data) else { return nil }
        return isNewer(release.version, than: current) ? release : nil
    }

    /// The release version comes from the tag ("v0.2.21" or "0.2.21"); the archive is the single
    /// application zip. Drafts and prereleases are never installed.
    nonisolated static func parse(_ data: Data) throws -> Release? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String else { throw UpdateError.noArchive }
        if object["draft"] as? Bool == true || object["prerelease"] as? Bool == true { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard components(version) != nil else { throw UpdateError.version }
        let assets = object["assets"] as? [[String: Any]] ?? []
        let archive = assets.first { asset in
            guard let name = asset["name"] as? String else { return false }
            return name.hasPrefix("Yasno-\(version)") && name.hasSuffix(".zip")
        }
        guard let link = archive?["browser_download_url"] as? String, let url = URL(string: link),
              url.scheme == "https" else { throw UpdateError.noArchive }
        return Release(version: version, archive: url)
    }

    nonisolated static func components(_ version: String) -> [Int]? {
        let parts = version.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, parts.allSatisfy({ $0 != nil && $0! >= 0 }) else { return nil }
        return parts.map { $0! }
    }

    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let new = components(candidate), let old = components(current) else { return false }
        for index in 0..<max(new.count, old.count) {
            let a = index < new.count ? new[index] : 0, b = index < old.count ? old[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    // MARK: Install

    private func install(_ release: Release) {
        let target = Bundle.main.bundleURL
        Task.detached(priority: .utility) { [weak self] in
            let result: Result<Void, UpdateError>
            do {
                try await Self.download(release, replacing: target)
                result = .success(())
            } catch let error as UpdateError { result = .failure(error) }
            catch { result = .failure(.network(error.localizedDescription)) }
            await self?.finishInstall(result, version: release.version)
        }
    }

    private func finishInstall(_ result: Result<Void, UpdateError>, version: String) {
        busy = false
        switch result {
        case .success:
            log.notice("Installed \(version, privacy: .public)")
            message = "Установлена версия \(version). Перезапуск…"
            relaunch()
        case .failure(let error):
            log.error("Update to \(version, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            message = Self.describe(error)
            schedule()
        }
    }

    nonisolated static func download(_ release: Release, replacing target: URL) async throws {
        try checkLocation(target)
        _ = try designatedRequirement()
        let files = FileManager.default
        // On the same volume as the application, so the final swap is a rename.
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: work) }
        var request = URLRequest(url: release.archive)
        request.timeoutInterval = 120
        let (downloaded, response) = try await URLSession.shared.download(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw UpdateError.network("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0)")
        }
        let archive = work.appendingPathComponent("update.zip")
        try files.moveItem(at: downloaded, to: archive)
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try files.createDirectory(at: unpacked, withIntermediateDirectories: false)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, unpacked.path]) else { throw UpdateError.extraction }
        let apps = (try? files.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil))?
            .filter { $0.pathExtension == "app" } ?? []
        guard apps.count == 1, let app = apps.first else { throw UpdateError.extraction }
        try verify(app, version: release.version)
        // An atomic exchange: the old copy disappears only when the new one is in place.
        _ = try files.replaceItemAt(target, withItemAt: app)
    }

    nonisolated static func checkLocation(_ target: URL) throws {
        // A translocated copy runs from a read-only random path; replacing it updates nothing.
        guard target.pathExtension == "app", !target.path.contains("/AppTranslocation/"),
              FileManager.default.isWritableFile(atPath: target.deletingLastPathComponent().path),
              FileManager.default.isWritableFile(atPath: target.path) else { throw UpdateError.location }
    }

    /// The new copy must satisfy the designated requirement of this process (which TCC
    /// recorded with the permissions), be notarized, and carry the advertised version.
    nonisolated static func verify(_ app: URL, version: String) throws {
        let requirement = try designatedRequirement()
        var staticCode: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &staticCode) == errSecSuccess, let staticCode else {
            throw UpdateError.signature("unreadable bundle")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        var error: Unmanaged<CFError>?
        guard SecStaticCodeCheckValidityWithErrors(staticCode, flags, requirement, &error) == errSecSuccess else {
            throw UpdateError.signature(error.map { String(describing: $0.takeRetainedValue()) } ?? "requirement")
        }
        var notarized: SecRequirement?
        guard SecRequirementCreateWithString("notarized" as CFString, [], &notarized) == errSecSuccess, let notarized,
              SecStaticCodeCheckValidity(staticCode, flags, notarized) == errSecSuccess else {
            throw UpdateError.signature("not notarized")
        }
        let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any] ?? [:]
        guard info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == version,
              isNewer(version, than: currentVersion) else { throw UpdateError.version }
    }

    /// The requirement TCC recorded for this copy. A development or ad-hoc build would lose
    /// the grants with any downloaded copy, so it is never replaced.
    nonisolated static func designatedRequirement() throws -> SecRequirement {
        var current: SecCode?
        var requirement: SecRequirement?
        var currentStatic: SecStaticCode?
        guard SecCodeCopySelf([], &current) == errSecSuccess, let current,
              SecCodeCopyStaticCode(current, [], &currentStatic) == errSecSuccess, let currentStatic,
              SecCodeCopyDesignatedRequirement(currentStatic, [], &requirement) == errSecSuccess, let requirement else {
            throw UpdateError.signature("no designated requirement")
        }
        var text: CFString?
        SecRequirementCopyString(requirement, [], &text)
        guard let text = text as String?, isDeveloperID(text) else {
            throw UpdateError.signature("running copy is not signed with Developer ID")
        }
        return requirement
    }

    nonisolated static func isDeveloperID(_ requirement: String) -> Bool {
        // 1.2.840.113635.100.6.1.13 marks a Developer ID Application leaf certificate.
        requirement.contains("anchor apple generic") && requirement.contains("field.1.2.840.113635.100.6.1.13")
            && requirement.contains("certificate leaf[subject.OU]")
    }

    @discardableResult nonisolated static func run(_ tool: String, _ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        do { try process.run() } catch { return false }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private func relaunch() {
        // The helper outlives this process, waits for it to quit, then opens the new copy.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while /bin/kill -0 \"$0\" 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$1\"",
                             String(ProcessInfo.processInfo.processIdentifier), Bundle.main.bundlePath]
        do { try process.run() } catch {
            message = "Обновление установлено. Перезапустите Ясно."
            return
        }
        onInstalled?()
    }

    nonisolated static func describe(_ error: UpdateError) -> String {
        switch error {
        case .network: return "Не удалось связаться с GitHub. Повторю завтра в 21:00."
        case .noArchive: return "В новом выпуске нет архива приложения."
        case .extraction: return "Не удалось распаковать обновление."
        case .signature: return "Обновление отклонено: подпись не совпадает с установленной. Разрешения не тронуты."
        case .version: return "Версия в архиве не совпадает с выпуском."
        case .location: return "Ясно не может заменить себя в этой папке. Перенесите программу в «Программы»."
        }
    }
}
