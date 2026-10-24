import XCTest
@testable import SwitchApp

final class AccessibleEditorTests: XCTestCase {
    private func bundle(_ paths: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Frameworks"),
                                                withIntermediateDirectories: true)
        for path in paths {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Contents/Frameworks/" + path),
                                                    withIntermediateDirectories: true)
        }
        addTeardownBlock { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        return root
    }

    func testRecognisesElectronHelpers() throws {
        XCTAssertTrue(AccessibleEditor.embedsChromium(try bundle(["Electron Framework.framework", "Canva Helper (Renderer).app"])))
    }

    func testRecognisesHelpersInsideTheChromiumFramework() throws {
        // The ChatGPT app: Codex Framework.framework/Helpers/Codex (Renderer).app.
        XCTAssertTrue(AccessibleEditor.embedsChromium(try bundle(["Codex Framework.framework/Helpers/Codex (Renderer).app"])))
    }

    func testOnlyListedShellsGetEnhancedUserInterface() throws {
        func attribute(_ id: String?, _ url: URL?, settable: Bool = false) -> String? {
            AccessibleEditor.attribute(bundleID: id, bundleURL: url, manualSettable: settable) as String?
        }
        let codex = try bundle(["Codex Framework.framework/Helpers/Codex (Renderer).app"])
        XCTAssertEqual(attribute("com.openai.codex", codex), "AXEnhancedUserInterface")
        XCTAssertEqual(attribute("com.google.Chrome", nil), "AXManualAccessibility")
        XCTAssertEqual(attribute("com.example.native", nil, settable: true), "AXManualAccessibility")
        // A Chromium fork outside the list, or an Electron app too busy to answer in time.
        XCTAssertEqual(attribute("ru.yandex.desktop.yandex-browser",
                                 try bundle(["Yandex Framework.framework/Helpers/Yandex Helper (Renderer).app"])), "AXManualAccessibility")
        XCTAssertEqual(attribute("com.tinyspeck.slackmacgap",
                                 try bundle(["Electron Framework.framework", "Slack Helper (Renderer).app"])), "AXManualAccessibility")
        XCTAssertNil(attribute("com.apple.TextEdit", try bundle(["Sparkle.framework/Helpers/Updater.app"])))
        XCTAssertNil(attribute(nil, nil))
    }

    func testLongFieldIsNotCopiedToLearnItShowsText() {
        XCTAssertFalse(AccessibleEditor.showsNoText(role: "AXTextArea", characterCount: { 50_000 },
                                                    value: { XCTFail("the whole document was read"); return nil }))
        XCTAssertTrue(AccessibleEditor.showsNoText(role: "AXTextArea", characterCount: { 1 }, value: { "\u{200B}" }))
        XCTAssertTrue(AccessibleEditor.showsNoText(role: "AXTextField", characterCount: { nil }, value: { "" }))
        XCTAssertFalse(AccessibleEditor.showsNoText(role: "AXTextField", characterCount: { nil }, value: { "abc" }))
        XCTAssertFalse(AccessibleEditor.showsNoText(role: "AXButton", characterCount: { 0 }, value: { "" }))
    }

    func testIgnoresNativeApplications() throws {
        XCTAssertFalse(AccessibleEditor.embedsChromium(try bundle(["Sparkle.framework/Helpers/Updater.app"])))
        XCTAssertFalse(AccessibleEditor.embedsChromium(URL(fileURLWithPath: "/nonexistent/Native.app")))
    }
    func testOpenAndSavePanelFieldTakesKeysInItsService() {
        func window(_ pid: pid_t, _ frame: CGRect, layer: Int = 0) -> [String: Any] {
            [kCGWindowOwnerPID as String: pid, kCGWindowLayer as String: layer,
             kCGWindowBounds as String: frame.dictionaryRepresentation]
        }
        let ids: [pid_t: String] = [52180: "com.apple.appkit.xpc.openAndSavePanelService", 900: "com.example.other"]
        let sheet = CGRect(x: 704, y: 317, width: 320, height: 158), field = CGPoint(x: 860, y: 400)
        func target(_ windows: [[String: Any]]) -> pid_t {
            AccessibleEditor.inputPID(at: field, pid: 51856, windows: windows) { ids[$0] }
        }
        // The service draws the sheet over the host's placeholder window of the same frame.
        XCTAssertEqual(target([window(52180, sheet), window(51856, sheet)]), 52180)
        XCTAssertEqual(target([window(51856, sheet), window(52180, sheet)]), 51856)
        // Another application's window on top, or a menu above everything, decides nothing.
        XCTAssertEqual(target([window(900, sheet), window(52180, sheet)]), 51856)
        XCTAssertEqual(target([window(1, sheet, layer: 25), window(52180, sheet)]), 52180)
        XCTAssertEqual(target([window(52180, CGRect(x: 0, y: 0, width: 10, height: 10))]), 51856)
    }
}
