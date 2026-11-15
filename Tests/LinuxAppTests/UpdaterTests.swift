import XCTest
@testable import YasnoLinux

final class UpdaterTests: XCTestCase {
    func release(_ tag: String, assets: [String], draft: Bool = false, prerelease: Bool = false) -> [String: Any] {
        ["tag_name": tag, "draft": draft, "prerelease": prerelease,
         "assets": assets.map { ["name": $0, "browser_download_url": "https://github.com/mavesr/yasno/releases/download/\(tag)/\($0)"] }]
    }

    func testPicksNewestLinuxReleaseForThisArchitecture() throws {
        let list: [[String: Any]] = [
            release("v0.2.27", assets: ["Yasno-0.2.27-arm64.zip"]),                       // the Mac edition
            release("win-v0.3.0", assets: ["yasno-windows-0.3.0-x64.zip"]),               // Windows
            release("linux-v0.1.2", assets: ["yasno-linux-0.1.2-x86_64.tar.gz", "yasno-linux-0.1.2-x86_64.tar.gz.sha256"]),
            release("linux-v0.1.10", assets: ["yasno-linux-0.1.10-x86_64.tar.gz", "yasno-linux-0.1.10-x86_64.tar.gz.sha256"]),
            release("linux-v0.2.0", assets: ["yasno-linux-0.2.0-aarch64.tar.gz"]),         // other architecture only
            release("linux-v0.3.0", assets: ["yasno-linux-0.3.0-x86_64.tar.gz"], draft: true),
            release("linux-v0.4.0", assets: ["yasno-linux-0.4.0-x86_64.tar.gz"], prerelease: true),
        ]
        let data = try JSONSerialization.data(withJSONObject: list)
        let found = try XCTUnwrap(Updater.parse(data, architecture: "x86_64"))
        XCTAssertEqual(found.version, "0.1.10")
        XCTAssertEqual(found.archive.lastPathComponent, "yasno-linux-0.1.10-x86_64.tar.gz")
        XCTAssertEqual(found.checksum?.lastPathComponent, "yasno-linux-0.1.10-x86_64.tar.gz.sha256")
        XCTAssertEqual(try Updater.parse(data, architecture: "aarch64")?.version, "0.2.0")
        XCTAssertNil(try Updater.parse(data, architecture: "riscv64"))
    }

    func testVersionOrder() {
        XCTAssertTrue(Updater.isNewer("0.1.10", than: "0.1.9"))
        XCTAssertTrue(Updater.isNewer("0.2", than: "0.1.9"))
        XCTAssertFalse(Updater.isNewer("0.1.0", than: "0.1"))
        XCTAssertFalse(Updater.isNewer("0.1.0-beta", than: "0.0.1"))
        XCTAssertFalse(Updater.isNewer("0.0.9", than: "0.1.0"))
    }

    func testDailyScheduleAndCatchUp() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        let morning = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 9))!
        let evening = calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 22))!
        XCTAssertEqual(Updater.nextCheck(after: morning, calendar: calendar),
                       calendar.date(from: DateComponents(year: 2026, month: 11, day: 15, hour: 21)))
        // Checked yesterday after 21:00: nothing missed in the morning, missed after today's 21:00.
        let yesterday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 21, minute: 30))!
        XCTAssertFalse(Updater.missedCheck(lastCheck: yesterday, now: morning, calendar: calendar))
        XCTAssertTrue(Updater.missedCheck(lastCheck: yesterday, now: evening, calendar: calendar))
        XCTAssertTrue(Updater.missedCheck(lastCheck: nil, now: morning, calendar: calendar))
    }

    // MARK: Install

    var work: URL!

    override func setUp() {
        work = FileManager.default.temporaryDirectory.appendingPathComponent("yasno-updater-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: work) }

    /// An installed copy (app/ with the marker) and a release archive whose yasno prints `reports`.
    func fixture(version: String, reports: String, corruptChecksum: Bool = false) throws -> (app: URL, release: Updater.Release) {
        let manager = FileManager.default
        let app = work.appendingPathComponent("install/app")
        try manager.createDirectory(at: app, withIntermediateDirectories: true)
        try "#!/bin/sh\necho 0.0.1\n".write(to: app.appendingPathComponent("yasno"), atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: app.appendingPathComponent("yasno").path)
        manager.createFile(atPath: app.appendingPathComponent(".yasno-install").path, contents: Data())
        let name = "yasno-linux-\(version)-\(Updater.architecture)"
        let staged = work.appendingPathComponent("stage/\(name)/app")
        try manager.createDirectory(at: staged, withIntermediateDirectories: true)
        try "#!/bin/sh\necho \(reports)\n".write(to: staged.appendingPathComponent("yasno"), atomically: true, encoding: .utf8)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: staged.appendingPathComponent("yasno").path)
        let archive = work.appendingPathComponent("\(name).tar.gz")
        XCTAssertNotNil(Shell.run(["tar", "-czf", archive.path, "-C", work.appendingPathComponent("stage").path, name]))
        var sum = Checksum.sha256(file: archive) ?? ""
        if corruptChecksum { sum = String(repeating: "0", count: 64) }
        let checksum = work.appendingPathComponent("\(name).tar.gz.sha256")
        try "\(sum)  \(name).tar.gz\n".write(to: checksum, atomically: true, encoding: .utf8)
        return (app, Updater.Release(version: version, archive: archive, checksum: checksum))
    }

    func testInstallReplacesTheCopy() throws {
        let (app, release) = try fixture(version: "9.9.9", reports: "9.9.9")
        let updater = Updater(settings: Settings(url: work.appendingPathComponent("s.json")), installDirectory: app)
        XCTAssertEqual(try updater.install(release), app)
        XCTAssertEqual(Shell.run([app.appendingPathComponent("yasno").path])?.trimmingCharacters(in: .whitespacesAndNewlines), "9.9.9")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent(".yasno-install").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: app.path + ".old"))
    }

    func testBadChecksumKeepsTheOldCopy() throws {
        let (app, release) = try fixture(version: "9.9.9", reports: "9.9.9", corruptChecksum: true)
        let updater = Updater(settings: Settings(url: work.appendingPathComponent("s.json")), installDirectory: app)
        XCTAssertThrowsError(try updater.install(release)) { XCTAssertEqual($0 as? Updater.UpdateError, .checksum) }
        XCTAssertEqual(Shell.run([app.appendingPathComponent("yasno").path])?.trimmingCharacters(in: .whitespacesAndNewlines), "0.0.1")
    }

    func testWrongVersionKeepsTheOldCopy() throws {
        let (app, release) = try fixture(version: "9.9.9", reports: "9.9.8")
        let updater = Updater(settings: Settings(url: work.appendingPathComponent("s.json")), installDirectory: app)
        XCTAssertThrowsError(try updater.install(release)) { XCTAssertEqual($0 as? Updater.UpdateError, .version) }
        XCTAssertEqual(Shell.run([app.appendingPathComponent("yasno").path])?.trimmingCharacters(in: .whitespacesAndNewlines), "0.0.1")
    }
}

final class DesktopParsingTests: XCTestCase {
    func testRegistryMapsDescriptionsToLayouts() {
        let xml = """
        <xkbConfigRegistry><layoutList>
        <layout><configItem><name>ru</name><shortDescription>ru</shortDescription><description>Russian</description></configItem>
        <variantList><variant><configItem><name>phonetic</name><description>Russian (phonetic)</description></configItem></variant></variantList></layout>
        <layout><configItem><name>ua</name><description>Ukrainian</description></configItem></layout>
        <layout><configItem><name>us</name><description>English (US)</description></configItem></layout>
        </layoutList></xkbConfigRegistry>
        """
        let registry = XkbRegistry.parse(xml)
        XCTAssertEqual(registry["Russian"]?.layout, "ru")
        XCTAssertEqual(registry["Russian (phonetic)"]?.variant, "phonetic")
        XCTAssertEqual(registry["Ukrainian"]?.layout, "ua")
        XCTAssertEqual(registry["English (US)"]?.layout, "us")
    }

    func testGVariantText() {
        XCTAssertEqual(GVariantText.strings("(['us', 'ru', 'it\\'s'],)"), ["us", "ru", "it's"])
        XCTAssertEqual(GVariantText.firstString("('{\"current\": 1}',)"), "{\"current\": 1}")
        XCTAssertEqual(GVariantText.firstInteger("(uint32 2,)"), 2)
    }

    func testLayoutIDs() {
        XCTAssertEqual(LayoutSpec(layout: "ru", variant: "", name: "Russian").id, "xkb:ru")
        XCTAssertEqual(LayoutSpec(layout: "ua", variant: "winkeys", name: "Ukrainian (Windows)").id, "xkb:ua(winkeys)")
    }

    func testExcludedAppsIgnoreCaseAndDesktopSuffix() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("yasno-settings-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings = Settings(url: url)
        XCTAssertTrue(settings.isExcluded("org.gnome.Terminal.desktop"))
        XCTAssertTrue(settings.isExcluded("kitty"))
        XCTAssertFalse(settings.isExcluded("firefox"))
        settings.update { $0.excludedApps["firefox"] = "Firefox" }
        XCTAssertTrue(Settings(url: url).isExcluded("Firefox"))
    }
}
