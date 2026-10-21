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

    func testIgnoresNativeApplications() throws {
        XCTAssertFalse(AccessibleEditor.embedsChromium(try bundle(["Sparkle.framework/Helpers/Updater.app"])))
        XCTAssertFalse(AccessibleEditor.embedsChromium(URL(fileURLWithPath: "/nonexistent/Native.app")))
    }
}
