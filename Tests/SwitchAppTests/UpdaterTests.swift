import XCTest
@testable import SwitchApp

final class UpdaterTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }()
    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    func testVersionOrder() {
        XCTAssertTrue(Updater.isNewer("0.2.21", than: "0.2.20"))
        XCTAssertTrue(Updater.isNewer("0.3", than: "0.2.20"))
        XCTAssertTrue(Updater.isNewer("0.2.100", than: "0.2.99"))
        XCTAssertFalse(Updater.isNewer("0.2.20", than: "0.2.20"))
        XCTAssertFalse(Updater.isNewer("0.2.20.0", than: "0.2.20"))
        XCTAssertFalse(Updater.isNewer("0.2.19", than: "0.2.20"))
        XCTAssertFalse(Updater.isNewer("0.2.21-beta", than: "0.2.20"))
        XCTAssertFalse(Updater.isNewer("", than: "0.2.20"))
    }

    func testNextCheckIsTheNextNinePM() {
        XCTAssertEqual(Updater.nextCheck(after: date(28, 9, 56), calendar: calendar), date(28, 21))
        XCTAssertEqual(Updater.nextCheck(after: date(28, 21), calendar: calendar), date(29, 21))
        XCTAssertEqual(Updater.nextCheck(after: date(28, 22, 30), calendar: calendar), date(29, 21))
    }

    func testMissedCheckCatchesUpAfterSleep() {
        XCTAssertTrue(Updater.missedCheck(lastCheck: nil, now: date(28, 10), calendar: calendar))
        XCTAssertFalse(Updater.missedCheck(lastCheck: date(27, 21, 1), now: date(28, 10), calendar: calendar))
        XCTAssertTrue(Updater.missedCheck(lastCheck: date(27, 21, 1), now: date(28, 23), calendar: calendar))
        XCTAssertFalse(Updater.missedCheck(lastCheck: date(28, 21, 2), now: date(28, 23), calendar: calendar))
    }

    func testRepositoryComesOnlyFromTheWebsiteEdition() {
        XCTAssertEqual(Updater.repository(info: ["YasnoUpdateRepository": "mavesr/yasno"]), "mavesr/yasno")
        XCTAssertNil(Updater.repository(info: [:]))
        XCTAssertNil(Updater.repository(info: ["YasnoUpdateRepository": "mavesr"]))
    }

    private func release(_ tag: String, assets: [String], draft: Bool = false, prerelease: Bool = false) -> Data {
        let list = assets.map { ["name": $0, "browser_download_url": "https://github.com/mavesr/yasno/releases/download/\(tag)/\($0)"] }
        return try! JSONSerialization.data(withJSONObject: ["tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": list])
    }

    func testParsePicksTheApplicationArchive() throws {
        let parsed = try Updater.parse(release("v0.2.21", assets: ["Yasno-0.2.21-universal-notarized.dmg", "Yasno-0.2.21-universal.zip"]))
        XCTAssertEqual(parsed?.version, "0.2.21")
        XCTAssertEqual(parsed?.archive.lastPathComponent, "Yasno-0.2.21-universal.zip")
    }

    func testParseSkipsDraftsAndPrereleases() throws {
        XCTAssertNil(try Updater.parse(release("v0.2.21", assets: ["Yasno-0.2.21-universal.zip"], prerelease: true)))
        XCTAssertNil(try Updater.parse(release("v0.2.21", assets: ["Yasno-0.2.21-universal.zip"], draft: true)))
    }

    func testParseRejectsAReleaseWithoutTheMatchingArchive() {
        XCTAssertThrowsError(try Updater.parse(release("v0.2.21", assets: ["Yasno-0.2.21-universal-notarized.dmg"])))
        XCTAssertThrowsError(try Updater.parse(release("v0.2.21", assets: ["Yasno-0.2.20-universal.zip"])))
        XCTAssertThrowsError(try Updater.parse(release("latest", assets: ["Yasno-latest-universal.zip"])))
    }

    func testOnlyDeveloperIDRequirementsAreAccepted() {
        let developerID = #"identifier "local.yasno.switcher" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = NJXU5X745X"#
        let development = #"identifier "local.yasno.switcher" and anchor apple generic and certificate leaf[subject.CN] = "Apple Development: Mykhailo Honieiev (ABCDE12345)" and certificate 1[field.1.2.840.113635.100.6.2.1] /* exists */"#
        XCTAssertTrue(Updater.isDeveloperID(developerID))
        XCTAssertFalse(Updater.isDeveloperID(development))
        XCTAssertFalse(Updater.isDeveloperID(#"cdhash H"0123""#))
    }

    func testTranslocatedOrForeignLocationsAreNotReplaced() {
        XCTAssertThrowsError(try Updater.checkLocation(URL(fileURLWithPath: "/private/var/folders/x/AppTranslocation/1/d/Ясно.app")))
        XCTAssertThrowsError(try Updater.checkLocation(URL(fileURLWithPath: "/usr/bin/true")))
    }
}
