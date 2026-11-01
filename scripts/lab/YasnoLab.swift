// Ясно лаборатория: a harmless window with every native AppKit text field, plus an optional
// WebKit window with the field lab page. Used as a typing target by the test drivers, so that no
// real document is ever typed into. Build the bundle with ./scripts/lab/build-lab.sh.
// usage: YasnoLab [--web <file or url>]
import Cocoa
import WebKit

final class Delegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var windows: [NSWindow] = []
    func applicationDidFinishLaunching(_ notification: Notification) {
        let main = NSWindow(contentRect: NSRect(x: 80, y: 120, width: 640, height: 560),
                            styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        main.title = "Ясно лаборатория"
        main.setAccessibilityIdentifier("lab-window")
        let content = NSView(frame: main.contentView!.bounds)
        content.autoresizingMask = [.width, .height]
        var y = content.bounds.height - 40
        func row(_ label: String, _ view: NSView, height: CGFloat = 24) {
            let caption = NSTextField(labelWithString: label)
            caption.frame = NSRect(x: 16, y: y - height + 4, width: 150, height: 20)
            caption.autoresizingMask = [.minYMargin]
            content.addSubview(caption)
            view.frame = NSRect(x: 170, y: y - height, width: content.bounds.width - 190, height: height)
            view.autoresizingMask = [.width, .minYMargin]
            content.addSubview(view)
            y -= height + 14
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        textView.isRichText = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.font = NSFont.systemFont(ofSize: 15)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.setAccessibilityIdentifier("textview")
        scroll.documentView = textView
        row("NSTextView", scroll, height: 120)
        let rich = NSScrollView()
        rich.hasVerticalScroller = true
        let richView = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 70))
        richView.isRichText = true
        richView.isAutomaticSpellingCorrectionEnabled = true
        richView.isAutomaticTextReplacementEnabled = true
        richView.isContinuousSpellCheckingEnabled = true
        richView.font = NSFont.systemFont(ofSize: 15)
        richView.isVerticallyResizable = true
        richView.autoresizingMask = [.width]
        richView.textContainer?.widthTracksTextView = true
        richView.setAccessibilityIdentifier("richview")
        rich.documentView = richView
        row("NSTextView rich+autocorrect", rich, height: 70)
        let field = NSTextField(string: "")
        field.placeholderString = "NSTextField"
        field.setAccessibilityIdentifier("textfield")
        row("NSTextField", field)
        let search = NSSearchField()
        search.setAccessibilityIdentifier("searchfield")
        search.sendsSearchStringImmediately = false
        row("NSSearchField", search)
        let secure = NSSecureTextField()
        secure.setAccessibilityIdentifier("secure")
        row("NSSecureTextField", secure)
        let combo = NSComboBox()
        combo.addItems(withObjectValues: ["привет", "hello", "мир"])
        combo.setAccessibilityIdentifier("combo")
        row("NSComboBox", combo)
        let token = NSTokenField()
        token.setAccessibilityIdentifier("token")
        row("NSTokenField", token)
        let number = NSTextField(string: "")
        number.formatter = NumberFormatter()
        number.placeholderString = "NumberFormatter"
        number.setAccessibilityIdentifier("number")
        row("NSTextField + formatter", number)
        main.contentView = content
        main.delegate = self
        main.makeKeyAndOrderFront(nil)
        main.makeFirstResponder(textView)
        windows.append(main)
        let args = CommandLine.arguments
        if let index = args.firstIndex(of: "--web"), index + 1 < args.count {
            let web = NSWindow(contentRect: NSRect(x: 740, y: 120, width: 900, height: 760),
                               styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            web.title = "Ясно лаборатория web"
            let configuration = WKWebViewConfiguration()
            let view = WKWebView(frame: web.contentView!.bounds, configuration: configuration)
            view.autoresizingMask = [.width, .height]
            let target = args[index + 1]
            if target.hasPrefix("http") { view.load(URLRequest(url: URL(string: target)!)) }
            else { view.loadFileURL(URL(fileURLWithPath: target), allowingReadAccessTo: URL(fileURLWithPath: target).deletingLastPathComponent()) }
            web.contentView = view
            web.orderFront(nil)
            windows.append(web)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let delegate = Delegate()
app.delegate = delegate
let menu = NSMenu()
let appItem = NSMenuItem(); menu.addItem(appItem)
let appMenu = NSMenu()
appMenu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
appItem.submenu = appMenu
let editItem = NSMenuItem(); menu.addItem(editItem)
let editMenu = NSMenu(title: "Edit")
editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
editItem.submenu = editMenu
app.mainMenu = menu
app.run()
