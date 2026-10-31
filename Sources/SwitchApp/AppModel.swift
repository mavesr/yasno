import Cocoa
import Carbon
import SwiftUI
import ServiceManagement
import os
import SwitchCore

final class AppModel: ObservableObject {
    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: "enabled"); refresh() } }
    @Published var accessibility = false
    @Published var inputMonitoring = false
    @Published var carambaRunning = false
    @Published var secureInput = false
    @Published var status = "Подготовка…"
    @Published var detail = ""
    @Published var layoutNames = ""
    @Published var ignoredWords: String { didSet { UserDefaults.standard.set(ignoredWords, forKey: "ignoredWords"); updateIgnored() } }
    @Published var excludedApps: [String: String] { didSet { UserDefaults.standard.set(excludedApps, forKey: "excludedApps"); refresh() } }
    @Published var loginEnabled = false
    @Published var corrections = 0
    @Published var correctSpelling: Bool { didSet { UserDefaults.standard.set(correctSpelling, forKey: "correctSpelling"); monitor.reset() } }
    let monitor = KeyboardMonitor()
    // Loaded on the worker (about 0.25 s of dictionary parsing), never on main at launch.
    // Only the serial worker touches it, so the lazy initialization is not shared.
    private(set) lazy var detector = Detector()
    // Set by the worker once the dictionaries are parsed. Until then a Space must not open a
    // gate that waits behind the load (0.25 s here, longer on a busy disk at login).
    private let detectorLoaded = OSAllocatedUnfairLock(initialState: false)
    private let worker = DispatchQueue(label: "local.yasno.analysis", qos: .userInitiated)
    // Setup IPC to other applications must never run on main: the event tap waits for main.
    // Worker only. A field that could not confirm its caret in time skips live correction
    // for a while instead of holding every following keystroke for another timeout.
    private var liveBlocked: (element: AXUIElement, until: TimeInterval)?
    private let accessibilityQueue = DispatchQueue(label: "local.yasno.accessibility", qos: .utility)
    private var layouts: [KeyboardLayout] = []
    private var timer: Timer?
    private var sourceObserver: NSObjectProtocol?
    private var layoutsObserver: NSObjectProtocol?
    private var appObserver: NSObjectProtocol?
    private var launchObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private static let carambaID = "tech.caramba.switcher"
    private var preferred: [String: String]
    private var globalPreferred: String?
    private var automaticSource: String?
    private var lastSource = ""
    private var receipt: Receipt?
    private var typingTask: DispatchWorkItem?
    private var pendingTypingToken: KeyboardMonitor.Token?
    private var pauseTask: DispatchWorkItem?
    private var focusObserver: AXObserver?
    private var observedPID: pid_t = 0
    private var activePID: pid_t = 0
    private var focusedElement: AXUIElement?
    private var ignored: Set<String> = []
    private var keyboardType: UInt32 = 0
    private struct MenuState: Equatable {
        let status: String
        let enabled: Bool
        let monitoring: Bool
        let layouts: String
    }
    private var lastMenuState: MenuState?
    private var shuttingDown = false
    var onStateChange: (() -> Void)?

    struct Receipt {
        let editor: AccessibleEditor
        let original: String
        let replacement: String
        let range: CFRange
        let caret: CFRange
        let sourceID: String
        let layoutID: String
        let cycle: LayoutCycle?
        var live = false
        var physicalKeys: [KeyboardLayout.KeyStroke]? = nil
        /// Made with keystrokes in a field without readable text: what followed the word, and
        /// the input revision right after the edit (range and caret mean nothing there).
        var keystrokes: (suffix: String, revision: UInt64)? = nil
    }

    init() {
        let defaults = UserDefaults.standard
        enabled = defaults.object(forKey: "enabled") as? Bool ?? true
        correctSpelling = defaults.object(forKey: "correctSpelling") as? Bool ?? true
        ignoredWords = defaults.string(forKey: "ignoredWords") ?? ""
        excludedApps = defaults.dictionary(forKey: "excludedApps") as? [String: String] ?? [
            "com.apple.Terminal": "Terminal", "com.googlecode.iterm2": "iTerm", "com.agilebits.onepassword7": "1Password",
            "com.1password.1password": "1Password", "com.apple.keychainaccess": "Keychain Access"
        ]
        preferred = defaults.dictionary(forKey: "preferredLayouts") as? [String: String] ?? [:]
        globalPreferred = defaults.string(forKey: "lastManualCyrillic")
        updateIgnored()
        reloadLayouts()
        let currentID = KeyboardLayout.currentID()
        lastSource = currentID
        monitor.syncSource(currentID)
        if let current = layouts.first(where: { $0.id == currentID }),
           current.languages.contains(where: { $0 == .russian || $0 == .ukrainian }) {
            globalPreferred = currentID
        }
        monitor.onToken = { [weak self] token in self?.process(token) }
        monitor.onProgress = { [weak self] token in self?.progress(token) }
        monitor.onManual = { [weak self] token in self?.manual(after: token) }
        monitor.onCancelAnalysis = { [weak self] in self?.cancelTypingTask() }
        monitor.onFault = { [weak self] in
            self?.detail = "Перехват приостановлен после повторных сбоев доставки событий и включится сам."
            self?.refresh()
        }
        monitor.onRecovered = { [weak self] in
            self?.receipt = nil
            self?.detail = "Ввод был задержан и отпущен без исправления."
        }
        sourceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.sourceChanged() }
        layoutsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifyEnabledKeyboardInputSourcesChanged as String), object: nil, queue: .main
        ) { [weak self] _ in self?.reloadLayouts(); self?.refresh() }
        appObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            let pid = AccessibleEditor.typingApplication()?.processIdentifier ?? 0
            if pid != self.activePID {
                self.activePID = pid; self.monitor.syncApplication(pid)
                SystemLexicon.shared.forget()
            }
            self.refresh()
        }
        // Caramba is tracked by launch/termination notifications instead of enumerating
        // all running applications on every refresh.
        carambaRunning = !NSRunningApplication.runningApplications(withBundleIdentifier: Self.carambaID).isEmpty
        let center = NSWorkspace.shared.notificationCenter
        launchObserver = center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier == Self.carambaID else { return }
            self?.update(\.carambaRunning, true); self?.refresh()
        }
        terminateObserver = center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            AccessibleEditor.forgetPreparedApplication(pid: app.processIdentifier)
            guard app.bundleIdentifier == Self.carambaID else { return }
            self?.update(\.carambaRunning, !NSRunningApplication.runningApplications(withBundleIdentifier: Self.carambaID).isEmpty)
            self?.refresh()
        }
        update(\.loginEnabled, SMAppService.mainApp.status == .enabled)
        worker.async { [self] in _ = detector; detectorLoaded.withLock { $0 = true } }
        // Process-wide AX timeout before the first refresh registers a focus observer on main:
        // an application that does not answer must not stall the UI queue for seconds.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.12)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in self?.refresh() }
        timer?.tolerance = 2 // Permissions and Secure Input are also re-checked on every key.
    }

    private func updateIgnored() {
        ignored = Set(ignoredWords.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { $0.lowercased() })
    }

    func shutdown(completion: @escaping () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard !shuttingDown else { return }
        shuttingDown = true
        monitor.enabled = false // Invalidate edits; the worker restores owned selections.
        cancelTypingTask()
        timer?.invalidate(); timer = nil
        if let sourceObserver { DistributedNotificationCenter.default().removeObserver(sourceObserver) }
        if let layoutsObserver { DistributedNotificationCenter.default().removeObserver(layoutsObserver) }
        for observer in [appObserver, launchObserver, terminateObserver].compactMap({ $0 }) {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        sourceObserver = nil; layoutsObserver = nil; appObserver = nil; launchObserver = nil; terminateObserver = nil
        if let focusObserver { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(focusObserver), .commonModes) }
        focusObserver = nil
        accessibilityQueue.async { AccessibleEditor.releasePreparedApplications() }
        // Do not replay keys into a word that is still temporarily selected. The
        // barrier waits for AX cleanup, then allow replay acknowledgements to drain.
        worker.async { [self] in
            accessibilityQueue.sync {}
            DispatchQueue.main.async { self.finishShutdown(completion: completion) }
        }
    }

    private func finishShutdown(completion: @escaping () -> Void) {
        if monitor.hasPendingInput {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [self] in finishShutdown(completion: completion) }
        } else { monitor.stop(); completion() }
    }

    private func update<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<AppModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value { self[keyPath: keyPath] = value }
    }

    private func reloadLayouts() {
        keyboardType = UInt32(LMGetKbdType())
        layouts = KeyboardLayout.installed()
        monitor.layouts = layouts
        update(\.layoutNames, layouts.map(\.name).joined(separator: " · "))
    }

    @discardableResult private func selectLayout(_ target: KeyboardLayout) -> Bool {
        automaticSource = target.id
        guard target.select(), KeyboardLayout.currentID() == target.id else { automaticSource = nil; return false }
        lastSource = target.id
        monitor.syncSource(target.id)
        return true
    }

    func sourceChanged() {
        let id = KeyboardLayout.currentID()
        guard id != lastSource else { if id == automaticSource { automaticSource = nil }; return }
        let programmatic = id == automaticSource
        lastSource = id; automaticSource = nil
        monitor.syncSource(id)
        guard !programmatic,
              let layout = layouts.first(where: { $0.id == id }),
              layout.languages.contains(where: { $0 == .russian || $0 == .ukrainian }),
              let bundle = AccessibleEditor.typingApplication()?.bundleIdentifier else { return }
        preferred[bundle] = id
        globalPreferred = id
        UserDefaults.standard.set(preferred, forKey: "preferredLayouts")
        UserDefaults.standard.set(id, forKey: "lastManualCyrillic")
    }

    func refresh() {
        guard !shuttingDown else { return }
        if monitor.resumeAfterQuietWindow() { detail = "" }
        update(\.accessibility, AXIsProcessTrusted())
        update(\.inputMonitoring, CGPreflightListenEventAccess())
        update(\.secureInput, IsSecureEventInputEnabled())
        if keyboardType != UInt32(LMGetKbdType()) { reloadLayouts() }
        let app = AccessibleEditor.typingApplication()
        // Login item status is an XPC query and only visible in our own window.
        if app?.processIdentifier == ProcessInfo.processInfo.processIdentifier {
            update(\.loginEnabled, SMAppService.mainApp.status == .enabled)
        }
        activePID = app?.processIdentifier ?? 0
        monitor.syncApplication(activePID)
        if accessibility, let pid = app?.processIdentifier, pid != observedPID { observeFocus(pid: pid) }
        let excluded = app?.bundleIdentifier.map { excludedApps[$0] != nil } ?? false
        let nextStatus: String
        if !enabled { nextStatus = "На паузе"; SystemLexicon.shared.forget() }
        else if carambaRunning { nextStatus = "Завершите Caramba" }
        else if !accessibility || !inputMonitoring { nextStatus = "Нужны разрешения macOS" }
        else if secureInput { nextStatus = "Защищённый ввод" }
        else if excluded { nextStatus = "Пауза в этом приложении" }
        else if layouts.count < 2 { nextStatus = "Нужны две раскладки" }
        else if monitor.faulted { nextStatus = "Пауза после сбоев" }
        else if !monitor.start() { nextStatus = "Не удалось подключить клавиатуру" }
        else { nextStatus = "Готово к работе" }
        update(\.status, nextStatus)
        monitor.enabled = enabled && !carambaRunning && accessibility && inputMonitoring && !secureInput && !excluded && layouts.count >= 2 && !monitor.faulted
        if lastSource.isEmpty { lastSource = KeyboardLayout.currentID() }
        let state = MenuState(status: status, enabled: enabled, monitoring: monitor.enabled, layouts: layoutNames)
        if state != lastMenuState { lastMenuState = state; onStateChange?() }
    }

    func openAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    func openInputMonitoring() {
        _ = CGRequestListenEventAccess()
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }

    func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
            detail = SMAppService.mainApp.status == .requiresApproval ? "Подтвердите автозапуск в настройках macOS." : ""
        } catch { detail = "Автозапуск: \(error.localizedDescription)" }
        refresh()
    }

    func excludeFrontmost() {
        guard let app = NSWorkspace.shared.frontmostApplication, let id = app.bundleIdentifier,
              id != Bundle.main.bundleIdentifier else { return }
        excludedApps[id] = app.localizedName ?? id
        monitor.reset()
    }

    private func observeFocus(pid: pid_t) {
        if let observer = focusObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
        focusObserver = nil
        observedPID = pid
        focusedElement = nil
        accessibilityQueue.async { AccessibleEditor.prepareApplication(pid: pid) }
        var observer: AXObserver?
        // The notification carries the new element; no AX request is made on main.
        let callback: AXObserverCallback = { _, element, notification, context in
            guard let context else { return }
            let model = Unmanaged<AppModel>.fromOpaque(context).takeUnretainedValue()
            if CFEqual(notification, kAXFocusedUIElementChangedNotification as CFString) {
                if let previous = model.focusedElement, CFEqual(element, previous) { return }
                model.focusedElement = element
            } else { model.focusedElement = nil }
            model.monitor.reset()
        }
        guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { return }
        let app = AXUIElementCreateApplication(pid)
        let context = Unmanaged.passUnretained(self).toOpaque()
        AXObserverAddNotification(observer, app, kAXFocusedUIElementChangedNotification as CFString, context)
        AXObserverAddNotification(observer, app, kAXFocusedWindowChangedNotification as CFString, context)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        focusObserver = observer
    }

    private func cancelTypingTask() {
        typingTask?.cancel(); typingTask = nil; pendingTypingToken = nil
        pauseTask?.cancel(); pauseTask = nil
    }

    private func progress(_ token: KeyboardMonitor.Token) {
        if token.liveConverted {
            cancelTypingTask()
            updateLiveReceipt(token)
            return
        }
        receipt = nil
        pendingTypingToken = token
        pauseTask?.cancel(); pauseTask = nil
        // A short word is checked only by Space, which a search field never gets (Countries:
        // гыф → usa). Once typing stops on it, it is checked as complete.
        if (2...3).contains(token.text.count) {
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pauseTask = nil
                self.process(token, whileTyping: true, paused: true)
            }
            pauseTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: task)
        }
        guard typingTask == nil, token.text.count >= 4 else { return }
        // Coalesce bursts without postponing until typing stops. A long continuous
        // word can be corrected at the next tick, with subsequent keys held/replayed.
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.typingTask = nil
            guard let latest = self.pendingTypingToken else { return }
            self.pendingTypingToken = nil
            self.process(latest, whileTyping: true)
        }
        typingTask = task
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.035, execute: task)
    }

    private func updateLiveReceipt(_ token: KeyboardMonitor.Token) {
        guard !token.text.isEmpty else { receipt = nil; return }
        guard let previous = receipt, previous.live, previous.cycle == nil,
              previous.editor.pid == token.pid, previous.layoutID == token.sourceID,
              let origin = layouts.first(where: { $0.id == previous.sourceID }),
              let current = layouts.first(where: { $0.id == token.sourceID }) else { return }
        let original: String
        if token.text.hasPrefix(previous.replacement),
           let tail = current.convert(String(token.text.dropFirst(previous.replacement.count)), to: origin) {
            original = previous.original + tail
        } else if previous.replacement.hasPrefix(token.text), previous.original.count == previous.replacement.count {
            original = String(previous.original.prefix(token.text.count))
        } else { receipt = nil; return }
        receipt = Receipt(editor: previous.editor, original: original, replacement: token.text,
            range: CFRange(location: previous.range.location, length: token.text.utf16.count),
            caret: CFRange(location: previous.range.location + token.text.utf16.count + token.suffix.utf16.count, length: 0),
            sourceID: previous.sourceID, layoutID: previous.layoutID, cycle: nil, live: true)
    }

    private func process(_ token: KeyboardMonitor.Token, whileTyping: Bool = false, paused: Bool = false) {
        if !whileTyping { cancelTypingTask() }
        if token.liveConverted {
            updateLiveReceipt(token)
            if whileTyping || !correctSpelling { return }
        } else { receipt = nil }
        guard monitor.enabled, monitor.revision == token.revision,
              let source = layouts.first(where: { $0.id == token.sourceID }) else { return }
        guard whileTyping else { correct(token, whileTyping: false); return }
        // Typing pauses are frequent and almost always negative, so check before
        // gating: a negative result never holds input. A key typed meanwhile changes
        // the revision, beginGate refuses, and the next pause retries.
        let request = self.request(for: token, source: source, whileTyping: true, paused: paused)
        worker.async { [self] in
            guard monitor.revision == token.revision, detector.mayCorrect(request) else { return }
            DispatchQueue.main.async { self.correct(token, whileTyping: true, paused: paused) }
        }
    }

    private func request(for token: KeyboardMonitor.Token, source: KeyboardLayout, whileTyping: Bool,
                         paused: Bool = false) -> CorrectionRequest {
        // The token already names the application that took its keys. Asking Accessibility
        // again here, on main, cost 0.4–16 ms on every live tick.
        let bundle = NSRunningApplication(processIdentifier: token.pid)?.bundleIdentifier ?? ""
        return CorrectionRequest(text: token.text, source: source, layouts: layouts, ignored: ignored,
                                 preferredTargetID: preferred[bundle] ?? globalPreferred,
                                 correctSpelling: correctSpelling, whileTyping: whileTyping,
                                 liveConverted: token.liveConverted, paused: paused)
    }

    private func correct(_ token: KeyboardMonitor.Token, whileTyping: Bool, settled: Bool = false, paused: Bool = false) {
        guard monitor.enabled, monitor.revision == token.revision,
              let source = layouts.first(where: { $0.id == token.sourceID }) else { return }
        let request = self.request(for: token, source: source, whileTyping: whileTyping, paused: paused)
        // A gate opened before the dictionaries are parsed would hold input behind the load.
        guard detectorLoaded.withLock({ $0 }) else { return }
        // Reserve before returning to the event stream, including replayed Space.
        // All dictionary/spelling work runs on the worker; negative results release
        // the gate without touching AX or doing browser IPC.
        guard monitor.beginGate(revision: token.revision) else { return }
        worker.async { [self] in
            defer { DispatchQueue.main.async { self.monitor.endGate(revision: token.revision) } }
            guard self.monitor.revision == token.revision else { return }
            // Live ticks were checked with mayCorrect before the gate.
            guard whileTyping || self.detector.mayCorrect(request) else { return }
            let deadline = ProcessInfo.processInfo.systemUptime + AccessibleEditor.operationTimeout
            guard self.monitor.revision == token.revision,
                  let editor = AccessibleEditor.focused(pid: token.pid) else { return }
            if editor.isCanvasTypingTarget {
                self.correctByKeystrokes(token, request: request, source: source, editor: editor, whileTyping: whileTyping)
                return
            }
            // Asked at most once per attempt, here on the worker, and only once an edit is near:
            // the same answer then serves the edit and its handling on main.
            var knownReceiver: pid_t?
            func receiver() -> pid_t {
                if knownReceiver == nil { knownReceiver = editor.keyReceiver }
                return knownReceiver!
            }
            func inPanel() -> Bool { AccessibleEditor.takesKeysInPanel(receiver: receiver(), pid: editor.pid) }
            // The panel's layout cannot be switched, so the rest of a word corrected while it is
            // typed would stay in the old layout. Correct it only once typing has stopped.
            if whileTyping, !settled, inPanel() {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                    guard self.monitor.revision == token.revision else { return }
                    self.correct(token, whileTyping: true, settled: true, paused: paused)
                }
                return
            }
            if whileTyping, let blocked = self.liveBlocked, CFEqual(blocked.element, editor.element),
               ProcessInfo.processInfo.systemUptime < blocked.until { return }
            let suffix = token.text + token.suffix
            // Key delivery and AX updates are asynchronous. Confirm the exact suffix
            // while later physical input is held, including a word with no trailing space.
            guard let caret = editor.waitForCaret(after: token, deadline: deadline,
                stillValid: { self.monitor.revision == token.revision }) else {
                guard self.monitor.revision == token.revision else { return }
                // Another editor drawn on a canvas: the field still shows nothing typed.
                if editor.exposesNoText {
                    self.correctByKeystrokes(token, request: request, source: source, editor: editor, whileTyping: whileTyping)
                } else if whileTyping {
                    // Only a genuine timeout counts; newer input invalidating the wait does not.
                    self.liveBlocked = (editor.element, ProcessInfo.processInfo.systemUptime + 30)
                }
                return
            }
            let suffixRange = CFRange(location: caret.location - suffix.utf16.count, length: suffix.utf16.count)
            let contextCount = min(suffixRange.location, 256)
            let context = contextCount > 0
                ? editor.text(in: CFRange(location: suffixRange.location - contextCount, length: contextCount)) ?? "" : ""
            // A token after a click may be only the suffix of an existing word (butto + ns).
            // If a context window cannot be read, do not assume it is a word boundary.
            if suffixRange.location > 0 {
                guard let left = editor.text(in: CFRange(location: suffixRange.location - 1, length: 1)),
                      TextSafety.hasLeftBoundary(left) else { return }
            }
            guard let suggestion = self.detector.correction(request, context: context) else { return }
            let range = CFRange(location: suffixRange.location, length: token.text.utf16.count)
            let result = editor.replace(range: range, expected: token.text, replacement: suggestion.replacement,
                                        caret: caret, stillValid: { self.monitor.revision == token.revision && !IsSecureEventInputEnabled() },
                                        commit: { self.monitor.commitGate(revision: token.revision) }, deadline: deadline, receiver: receiver())
            let panel = inPanel()
            DispatchQueue.main.async {
                self.handle(result, editor: editor, range: range, caret: caret, original: token.text,
                            replacement: suggestion.replacement, sourceID: source.id, target: suggestion.target, live: whileTyping, panel: panel)
            }
        }
    }

    /// Worker, inside the gate. Nothing can be read back from such a field, so the edit erases
    /// only what this token typed and keeps the text before it unread and untouched.
    private func correctByKeystrokes(_ token: KeyboardMonitor.Token, request: CorrectionRequest, source: KeyboardLayout,
                                     editor: AccessibleEditor, whileTyping: Bool) {
        guard let suggestion = detector.correction(request, context: ""),
              let edit = Self.keystrokeEdit(for: token, suggestion: suggestion, source: source,
                                            blind: AccessibleEditor.blind || editor.showsRemoteScreen),
              monitor.revision == token.revision, !IsSecureEventInputEnabled(),
              monitor.commitGate(revision: token.revision) else { return }
        let typed = editor.showsRemoteScreen ? typeOnRemoteScreen(edit, in: suggestion.target) : KeyboardMonitor.typeKeystrokes(edit)
        let result: AccessibleEditor.EditResult = typed ? .success : .failed
        DispatchQueue.main.async {
            self.handle(result, editor: editor, range: CFRange(), caret: CFRange(), original: token.text,
                        replacement: suggestion.replacement, sourceID: source.id, target: suggestion.target,
                        live: whileTyping, keystrokeSuffix: token.suffix)
        }
    }

    /// Worker, inside the gate. Screen Sharing ignores the text of a key event and sends on what
    /// its key types in the layout selected here (a posted «п» arrived as «ф»). So the layout is
    /// selected first and the replacement pressed with that layout's keys.
    private func typeOnRemoteScreen(_ edit: KeystrokeEdit, in layout: KeyboardLayout) -> Bool {
        Self.typeOnRemoteScreen(edit, in: layout, select: {
            var selected = false
            DispatchQueue.main.sync { selected = KeyboardLayout.currentID() == layout.id || self.selectLayout(layout) }
            return selected
        }, erase: { KeyboardMonitor.typeKeystrokes(KeystrokeEdit(deletions: edit.deletions, insertion: "")) },
           // Screen Sharing learns of the new layout from a notification, after the selection returns.
           pause: { Thread.sleep(forTimeInterval: 0.1) }, type: KeyboardMonitor.typeStrokes)
    }

    /// The layout is selected before anything is erased: a layout that cannot be selected must
    /// leave the word as typed, like every other refused edit. Erasing overlaps the wait.
    static func typeOnRemoteScreen(_ edit: KeystrokeEdit, in layout: KeyboardLayout, select: () -> Bool, erase: () -> Bool,
                                   pause: () -> Void, type: ([KeyboardLayout.KeyStroke]) -> Bool) -> Bool {
        let strokes = edit.insertion.compactMap(layout.stroke(for:))
        guard strokes.count == edit.insertion.count, select(), erase() else { return false }
        pause()
        return type(strokes)
    }

    /// An automatic correction made blind, or nil where erasing by count is unsafe. The field
    /// may already hold the application's own spelling fix, so only layout changes are made.
    /// The App Store build cannot see the field at all: a lone letter there is as likely a
    /// shortcut on a canvas or a shell command as a word, and only Shift converts it.
    static func keystrokeEdit(for token: KeyboardMonitor.Token, suggestion: Suggestion, source: KeyboardLayout,
                              blind: Bool) -> KeystrokeEdit? {
        guard suggestion.target.id != source.id, !(blind && token.text.count == 1) else { return nil }
        return KeystrokeEdit(typed: token.text, replacement: suggestion.replacement, suffix: token.suffix)
    }

    private func handle(_ result: AccessibleEditor.EditResult, editor: AccessibleEditor, range: CFRange,
                        caret: CFRange, original: String, replacement: String, sourceID: String, target: KeyboardLayout,
                        cycle: LayoutCycle? = nil, live: Bool = false,
                        physicalKeys: [KeyboardLayout.KeyStroke]? = nil, keystrokeSuffix: String? = nil,
                        panel: Bool = false) {
        switch result {
        case .success:
            // `panel`: the field takes keys in an Open/Save panel service (read on the worker, see
            // keyReceiver). The panel keeps its own layout: the next keys start a new word.
            // The word just typed is gone from the field: a later Shift or Backspace must
            // not act on it. A layout change resets too; a spelling fix keeps the layout.
            // Before the receipt, which records the revision a keystroke undo counts from.
            if !live || panel { monitor.reset() }
            corrections += 1
            receipt = Receipt(editor: editor, original: original, replacement: replacement,
                              range: CFRange(location: range.location, length: replacement.utf16.count),
                              caret: CFRange(location: caret.length == 0
                                  ? caret.location + replacement.utf16.count - range.length
                                  : range.location + replacement.utf16.count, length: 0), sourceID: sourceID,
                              layoutID: target.id, cycle: cycle, live: live, physicalKeys: physicalKeys,
                              keystrokes: keystrokeSuffix.map { ($0, monitor.revision) })
            // The transaction confirmed focus just before returning. Repeating the full AX
            // focus lookup here would hold queued input on main for no extra safety.
            if AccessibleEditor.typingApplication()?.processIdentifier == editor.pid, !panel {
                if cycle != nil {
                    guard selectManually(target, bundleID: NSRunningApplication(processIdentifier: editor.pid)?.bundleIdentifier) else { return }
                } else if !selectLayout(target) { detail = "Текст исправлен, но раскладку переключить не удалось."; return }
                if live {
                    monitor.resumeAfterLiveCorrection(text: replacement, sourceID: target.id, pid: editor.pid)
                }
            }
            // Selecting the layout restarts the input revision; a later Shift counts from here.
            if keystrokeSuffix != nil { receipt?.keystrokes?.revision = monitor.revision }
            detail = cycle == nil ? "Исправлено. Короткий Shift — отменить." : "Раскладка: \(target.name). Ещё короткий Shift — следующий язык."
        case .unsupported: detail = "Это поле не поддерживает безопасную замену текста."
        case .failed: detail = "Не удалось подтвердить замену в этом поле."
        case .stale: break
        }
    }

    /// Worker, inside the gate. Shift in a field without readable text: undo or cycle the last
    /// keystroke edit while nothing was typed since, else convert the word just typed.
    /// Returns false when there is nothing to convert.
    private func manualByKeystrokes(editor: AccessibleEditor, expectedToken: KeyboardMonitor.Token?, receipt: Receipt?,
                                    revision: UInt64, sourceID: String, layouts: [KeyboardLayout],
                                    preferredID: String?, bundleID: String?) -> Bool {
        func type(_ edit: KeystrokeEdit?, in layout: KeyboardLayout) -> Bool {
            guard let edit, monitor.revision == revision, !IsSecureEventInputEnabled(),
                  monitor.commitGate(revision: revision) else { return false }
            return editor.showsRemoteScreen ? typeOnRemoteScreen(edit, in: layout) : KeyboardMonitor.typeKeystrokes(edit)
        }
        if let receipt, let keystrokes = receipt.keystrokes, CFEqual(receipt.editor.element, editor.element),
           expectedToken.map({ $0.pid == editor.pid && [receipt.original, receipt.replacement].contains($0.text) })
               ?? (revision == keystrokes.revision &+ 1) {
            let suffix = expectedToken?.suffix ?? keystrokes.suffix
            guard let origin = layouts.first(where: { $0.id == receipt.sourceID }) else { return true }
            if let cycle = receipt.cycle {
                guard sourceID == receipt.layoutID, let nextID = cycle.next(after: sourceID),
                      let target = layouts.first(where: { $0.id == nextID }),
                      let converted = target.id == origin.id ? receipt.original
                          : detector.convertTextManually(receipt.original, source: origin, target: target, physicalKeys: receipt.physicalKeys),
                      type(KeystrokeEdit(typed: receipt.replacement, replacement: converted, suffix: suffix), in: target) else { return true }
                DispatchQueue.main.async {
                    self.handle(.success, editor: editor, range: CFRange(), caret: CFRange(), original: receipt.original,
                                replacement: converted, sourceID: receipt.sourceID, target: target, cycle: cycle,
                                physicalKeys: receipt.physicalKeys, keystrokeSuffix: suffix)
                }
                return true
            }
            guard type(KeystrokeEdit(typed: receipt.replacement, replacement: receipt.original, suffix: suffix), in: origin) else { return true }
            DispatchQueue.main.async {
                let compatible = KeyboardLayout.cycleOrder(layouts).filter { origin.convert(receipt.original, to: $0) != nil }
                self.receipt = Receipt(editor: editor, original: receipt.original, replacement: receipt.original,
                    range: CFRange(), caret: CFRange(), sourceID: receipt.sourceID, layoutID: receipt.sourceID,
                    cycle: LayoutCycle(layoutIDs: compatible.map(\.id)), keystrokes: (suffix, self.monitor.revision))
                _ = self.selectManually(origin, bundleID: bundleID)
                if receipt.live, suffix.isEmpty {
                    self.monitor.resumeAfterLiveCorrection(text: receipt.original, sourceID: origin.id, pid: editor.pid)
                }
                self.receipt?.keystrokes?.revision = self.monitor.revision
                self.detail = "Замена отменена."
            }
            return true
        }
        guard let token = expectedToken, token.pid == editor.pid, token.sourceID == sourceID, !token.text.isEmpty,
              let source = layouts.first(where: { $0.id == sourceID }) else { return expectedToken != nil }
        guard let candidate = detector.convertManually(token.text, source: source, layouts: layouts,
                                                       preferredTargetID: preferredID, physicalKeys: token.physicalKeys),
              type(KeystrokeEdit(typed: token.text, replacement: candidate.replacement, suffix: token.suffix), in: candidate.target) else { return true }
        let compatible = KeyboardLayout.cycleOrder(layouts).filter { source.convert(token.text, to: $0) != nil }
        let cycle = LayoutCycle(layoutIDs: compatible.map(\.id), startingID: sourceID, firstTargetID: candidate.target.id)
        DispatchQueue.main.async {
            self.handle(.success, editor: editor, range: CFRange(), caret: CFRange(), original: token.text,
                        replacement: candidate.replacement, sourceID: sourceID, target: candidate.target, cycle: cycle,
                        physicalKeys: token.physicalKeys, keystrokeSuffix: token.suffix)
        }
        return true
    }

    @discardableResult
    private func selectManually(_ target: KeyboardLayout, bundleID: String?) -> Bool {
        guard selectLayout(target) else {
            detail = "Не удалось включить раскладку \(target.name)."
            return false
        }
        if target.languages.contains(.russian) || target.languages.contains(.ukrainian) {
            if let bundleID { preferred[bundleID] = target.id }
            globalPreferred = target.id
            UserDefaults.standard.set(preferred, forKey: "preferredLayouts")
            UserDefaults.standard.set(target.id, forKey: "lastManualCyrillic")
        }
        return true
    }

    private func switchLayoutOnly(sourceID: String, layouts: [KeyboardLayout], bundleID: String?) {
        let ordered = KeyboardLayout.cycleOrder(layouts)
        let cycle = LayoutCycle(layoutIDs: ordered.map(\.id))
        guard let nextID = cycle.next(after: sourceID), let target = ordered.first(where: { $0.id == nextID }) else { return }
        receipt = nil
        if selectManually(target, bundleID: bundleID) { detail = "Раскладка: \(target.name)." }
    }

    private func manual(after expectedToken: KeyboardMonitor.Token?) {
        cancelTypingTask()
        guard monitor.enabled, let app = AccessibleEditor.typingApplication() else { return }
        sourceChanged()
        let revision = monitor.revision, layouts = self.layouts, receipt = self.receipt
        let sourceID = KeyboardLayout.currentID()
        let preferredID = preferred[app.bundleIdentifier ?? ""] ?? globalPreferred
        // Reserve on Shift release, before returning to the input stream. Reserving from
        // the worker allowed the following key to invalidate the requested conversion.
        guard monitor.beginGate(revision: revision) else { return }
        worker.async { [weak self] in
            guard let self else { return }
            defer { DispatchQueue.main.async { self.monitor.endGate(revision: revision) } }
            let deadline = ProcessInfo.processInfo.systemUptime + AccessibleEditor.operationTimeout
            func switchOnly() {
                // A known typed word means "convert this word", never silently switch
                // only the layout because a busy renderer has not exposed its caret yet.
                guard expectedToken == nil else { return }
                DispatchQueue.main.async {
                    guard self.monitor.revision == revision, self.monitor.enabled, !IsSecureEventInputEnabled(),
                          AccessibleEditor.typingApplication()?.processIdentifier == app.processIdentifier else { return }
                    self.switchLayoutOnly(sourceID: sourceID, layouts: layouts, bundleID: app.bundleIdentifier)
                }
            }
            guard let editor = AccessibleEditor.focused(pid: app.processIdentifier) else {
                if expectedToken == nil { switchOnly() }
                return
            }
            // A keystroke edit is undone with keystrokes too: such a field has nothing to read back.
            if editor.isCanvasTypingTarget || (receipt?.keystrokes != nil && receipt.map { CFEqual($0.editor.element, editor.element) } == true) {
                if !self.manualByKeystrokes(editor: editor, expectedToken: expectedToken, receipt: receipt, revision: revision,
                                            sourceID: sourceID, layouts: layouts, preferredID: preferredID, bundleID: app.bundleIdentifier) {
                    switchOnly()
                }
                return
            }
            let caret: CFRange?
            if let expectedToken, expectedToken.pid == app.processIdentifier, expectedToken.sourceID == sourceID {
                caret = editor.waitForCaret(after: expectedToken, deadline: deadline, stillValid: { self.monitor.revision == revision })
            } else { caret = editor.selection }
            guard let caret, self.monitor.revision == revision else {
                if expectedToken == nil { switchOnly() }
                return
            }
            if let receipt, CFEqual(receipt.editor.element, editor.element),
               caret.location >= receipt.range.location, caret.location <= receipt.caret.location, caret.length == 0,
               editor.text(in: receipt.range) == receipt.replacement {
                if let cycle = receipt.cycle, sourceID == receipt.layoutID,
                   let nextID = cycle.next(after: sourceID), let target = layouts.first(where: { $0.id == nextID }),
                   let origin = layouts.first(where: { $0.id == receipt.sourceID }),
                   let converted = target.id == origin.id ? receipt.original : self.detector.convertTextManually(receipt.original, source: origin, target: target, physicalKeys: receipt.physicalKeys) {
                    let receiver = editor.keyReceiver
                    let result = editor.replace(range: receipt.range, expected: receipt.replacement,
                                                replacement: converted, caret: caret,
                                                stillValid: { self.monitor.revision == revision && !IsSecureEventInputEnabled() },
                                                commit: { self.monitor.commitGate(revision: revision) }, deadline: deadline, receiver: receiver)
                    let panel = AccessibleEditor.takesKeysInPanel(receiver: receiver, pid: editor.pid)
                    DispatchQueue.main.async {
                        self.handle(result, editor: editor, range: receipt.range, caret: caret, original: receipt.original,
                                    replacement: converted, sourceID: receipt.sourceID, target: target, cycle: cycle,
                                    physicalKeys: receipt.physicalKeys, panel: panel)
                    }
                    return
                }
                // Only an automatic correction has a one-press undo. A manual conversion
                // keeps cycling all layouts, using the original physical key sequence.
                if receipt.cycle == nil {
                let receiver = editor.keyReceiver
                let result = editor.replace(range: receipt.range, expected: receipt.replacement,
                                            replacement: receipt.original, caret: caret,
                                            stillValid: { self.monitor.revision == revision && !IsSecureEventInputEnabled() },
                                            commit: { self.monitor.commitGate(revision: revision) }, deadline: deadline, receiver: receiver)
                DispatchQueue.main.async {
                    if case .success = result {
                        guard let origin = layouts.first(where: { $0.id == receipt.sourceID }) else { return }
                        let compatible = KeyboardLayout.cycleOrder(layouts).filter { origin.convert(receipt.original, to: $0) != nil }
                        self.receipt = Receipt(editor: editor, original: receipt.original, replacement: receipt.original,
                            range: CFRange(location: receipt.range.location, length: receipt.original.utf16.count),
                            caret: CFRange(location: caret.location + receipt.original.utf16.count - receipt.replacement.utf16.count, length: 0),
                            sourceID: receipt.sourceID, layoutID: receipt.sourceID,
                            cycle: LayoutCycle(layoutIDs: compatible.map(\.id)))
                        _ = self.selectManually(origin, bundleID: app.bundleIdentifier)
                        if receipt.live, expectedToken?.suffix.isEmpty == true {
                            self.monitor.resumeAfterLiveCorrection(text: receipt.original, sourceID: origin.id, pid: editor.pid)
                        }
                        self.detail = "Замена отменена."
                    }
                }
                return
                }
            }
            guard let source = layouts.first(where: { $0.id == sourceID }) else { switchOnly(); return }
            var range = caret
            var text: String
            if caret.length > 0 {
                guard caret.length <= 4096, let selected = editor.text(in: caret) else { return }
                text = selected
            } else {
                let count = min(caret.location, 513)
                guard count > 0, let prefix = editor.text(in: CFRange(location: caret.location - count, length: count)) else { switchOnly(); return }
                let right = editor.text(in: CFRange(location: caret.location, length: 1)) ?? ""
                guard let last = TextSafety.manualWord(onCurrentLine: prefix,
                    recentText: expectedToken?.text, recentSuffix: expectedToken?.suffix ?? "", rightContext: right)
                else { switchOnly(); return }
                let word = last.text, trailingCount = last.trailingUTF16
                // A bounded context must not turn only the tail of a longer URL.
                guard word.utf16.count <= 512,
                      caret.location <= count || word.utf16.count + trailingCount < count else { return }
                range = CFRange(location: caret.location - trailingCount - word.utf16.count, length: word.utf16.count)
                text = word
            }
            let physicalKeys = expectedToken?.text == text ? expectedToken?.physicalKeys : nil
            guard let candidate = self.detector.convertManually(text, source: source, layouts: layouts,
                                                                preferredTargetID: preferredID, physicalKeys: physicalKeys) else { switchOnly(); return }
            let compatible = KeyboardLayout.cycleOrder(layouts).filter { source.convert(text, to: $0) != nil }
            let cycle = LayoutCycle(layoutIDs: compatible.map(\.id), startingID: sourceID, firstTargetID: candidate.target.id)
            let receiver = editor.keyReceiver
            let result = editor.replace(range: range, expected: text, replacement: candidate.replacement, caret: caret,
                                        stillValid: { self.monitor.revision == revision && !IsSecureEventInputEnabled() },
                                        commit: { self.monitor.commitGate(revision: revision) }, deadline: deadline, receiver: receiver)
            let panel = AccessibleEditor.takesKeysInPanel(receiver: receiver, pid: editor.pid)
            DispatchQueue.main.async {
                self.handle(result, editor: editor, range: range, caret: caret, original: text,
                            replacement: candidate.replacement, sourceID: sourceID, target: candidate.target, cycle: cycle,
                            physicalKeys: physicalKeys, panel: panel)
            }
        }
    }
}
