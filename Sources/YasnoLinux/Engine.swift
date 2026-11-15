import Foundation
import SwitchCore

/// Types an edit on the virtual keyboard: Backspaces, then the replacement pressed with the
/// keys of its layout. Linux has no way to post text, so this is how every edit is made —
/// the same way the Mac edition types into Screen Sharing (AppModel.typeOnRemoteScreen).
public protocol Typist: AnyObject {
    /// Waits until the keys already forwarded have reached the desktop.
    func settle()
    func erase(_ count: Int)
    func press(_ strokes: [KeyboardLayout.KeyStroke])
    func pause()
}

/// The Linux counterpart of AppModel in its keystroke ("blind") mode: the same decisions
/// through Detector, the same receipts for a Shift undo and the same layout cycle.
/// YASNO_TRACE=1: decisions (not the text of other words) to standard error, for testing.
let tracing = ProcessInfo.processInfo.environment["YASNO_TRACE"] == "1"
func trace(_ message: @autoclosure () -> String) {
    guard tracing else { return }
    FileHandle.standardError.write(Data(("[yasno] " + message() + "\n").utf8))
}

public final class Engine {
    public struct Receipt {
        let original: String
        let replacement: String
        let sourceID: String
        let layoutID: String
        let cycle: LayoutCycle?
        var live = false
        var physicalKeys: [KeyboardLayout.KeyStroke]? = nil
        var keystrokes: (suffix: String, revision: UInt64)? = nil
        let app: String
    }

    public let queue: DispatchQueue
    let worker = DispatchQueue(label: "yasno.analysis", qos: .userInitiated)
    public let hub: InputHub
    public let monitor: WordMonitor
    let settings: Settings
    let typist: Typist
    public var backend: LayoutBackend?
    private(set) lazy var detector = Detector()
    private let loadedLock = NSLock()
    private var loaded = false
    var detectorLoaded: Bool { loadedLock.lock(); defer { loadedLock.unlock() }; return loaded }

    public private(set) var layouts: [KeyboardLayout] = []
    private(set) var specs: [LayoutSpec] = []
    private var ignored: Set<String> = []
    private var automaticSource: String?
    private var lastSource = ""
    private(set) var receipt: Receipt?
    private var typingTask: DispatchWorkItem?
    private var pendingTypingToken: WordMonitor.Token?
    private var pauseTask: DispatchWorkItem?
    public private(set) var corrections = 0
    public private(set) var detail = ""
    public var onChange: (() -> Void)?
    /// The application that has the keys, cached by refresh() and at each word start.
    private(set) var activeApp: (id: String, name: String)?
    public var monitoringAllowed: () -> Bool = { true }
    public var secureInput = false
    private var allowed = false

    public init(hub: InputHub, typist: Typist, settings: Settings, backend: LayoutBackend?,
                queue: DispatchQueue = DispatchQueue(label: "yasno.engine", qos: .userInteractive)) {
        self.hub = hub; self.typist = typist; self.settings = settings; self.backend = backend; self.queue = queue
        monitor = WordMonitor(hub: hub)
        monitor.onToken = { [weak self] in self?.process($0) }
        monitor.onProgress = { [weak self] in self?.progress($0) }
        monitor.onManual = { [weak self] in self?.manual(after: $0) }
        monitor.onCancelAnalysis = { [weak self] in self?.cancelTypingTask() }
        monitor.currentSourceID = { [weak self] in self?.currentID() ?? "" }
        monitor.currentApp = { [weak self] in self?.activeApp?.id ?? "" }
        monitor.onWordStart = { [weak self] in
            guard let self else { return }
            _ = self.lookupApp()
            self.apply(allowed: self.allowed)
        }
        monitor.secureInput = { [weak self] in self?.secureInput ?? false }
        hub.observe = { [weak self] event, sequence, boundary in
            guard let self else { return }
            self.queue.async {
                if sequence > 0 { self.hub.markObserved(sequence) }
                self.monitor.receive(event)
                if let boundary { self.hub.finishBoundary(boundary) }
            }
        }
        hub.onStall = { [weak self] in
            self?.queue.async {
                self?.receipt = nil
                self?.monitor.reset()
                self?.setDetail("Ввод был задержан и отпущен без исправления.")
            }
        }
        updateIgnored()
        KeyboardLayout.selector = { [weak self] layout in self?.selectLayout(layout) ?? false }
        KeyboardLayout.currentProvider = { [weak self] in self?.currentID() ?? "" }
        KeyboardLayout.installedProvider = { [weak self] in self?.layouts ?? [] }
    }

    /// Parses the dictionaries on the worker, as the Mac app does at launch.
    public func loadDetector(completion: (() -> Void)? = nil) {
        worker.async { [self] in
            _ = detector
            loadedLock.lock(); loaded = true; loadedLock.unlock()
            completion?()
        }
    }

    func updateIgnored() {
        ignored = Set(settings.values.ignoredWords.split(whereSeparator: { $0.isWhitespace || $0 == "," }).map { $0.lowercased() })
    }

    private func setDetail(_ text: String) { detail = text; onChange?() }

    // MARK: Layouts

    /// Engine queue. Reads the desktop's layout list; true when it changed.
    @discardableResult public func reloadLayouts() -> Bool {
        let next = backend?.layouts() ?? []
        guard next != specs || layouts.isEmpty && !next.isEmpty else { return false }
        specs = next
        var built: [KeyboardLayout] = []
        for spec in next {
            guard let layout = XkbTables.layout(spec), !built.contains(where: { $0.id == layout.id }) else { continue }
            built.append(layout)
        }
        layouts = built
        monitor.layouts = built
        monitor.reset()
        return true
    }

    /// At launch, as on the Mac: a Cyrillic layout selected now is the preferred one until the
    /// user picks another, so an ambiguous Russian/Ukrainian word follows it.
    public func adoptCurrentCyrillic() {
        let id = currentID()
        lastSource = id
        monitor.syncSource(id)
        if settings.values.lastManualCyrillic == nil, let layout = layouts.first(where: { $0.id == id }),
           layout.languages.contains(where: { $0 == .russian || $0 == .ukrainian }) {
            settings.update { $0.lastManualCyrillic = id }
        }
    }

    public var layoutNames: String { layouts.map(\.name).joined(separator: " · ") }

    /// Any thread: the layout as the desktop reports it, for traces.
    func currentIDSafe() -> String {
        guard let index = backend?.currentIndex(), index >= 0, index < specs.count else { return "?" }
        return specs[index].id
    }

    func currentID() -> String {
        guard let index = backend?.currentIndex(), index >= 0, index < specs.count else { return "" }
        return specs[index].id
    }

    @discardableResult func selectLayout(_ target: KeyboardLayout) -> Bool {
        guard let index = specs.firstIndex(where: { $0.id == target.id }), let backend else { return false }
        automaticSource = target.id
        guard backend.select(index: index), backend.currentIndex() == index else {
            automaticSource = nil; return false
        }
        lastSource = target.id
        monitor.syncSource(target.id)
        return true
    }

    func lookupApp() -> String {
        if let app = backend?.focusedApplication() { activeApp = app }
        return activeApp?.id ?? ""
    }

    /// Engine queue. A layout the user picked (not one Yasno selected) becomes the preferred
    /// Cyrillic layout for this application and in general, as on the Mac.
    public func sourceChanged() {
        let id = currentID()
        guard id != lastSource else { if id == automaticSource { automaticSource = nil }; return }
        let programmatic = id == automaticSource
        lastSource = id; automaticSource = nil
        monitor.syncSource(id)
        guard !programmatic, let layout = layouts.first(where: { $0.id == id }),
              layout.languages.contains(where: { $0 == .russian || $0 == .ukrainian }) else { return }
        let app = activeApp?.id ?? ""
        settings.update { values in
            if !app.isEmpty { values.preferredLayouts[app] = id }
            values.lastManualCyrillic = id
        }
    }

    // MARK: Typing

    private func cancelTypingTask() {
        typingTask?.cancel(); typingTask = nil; pendingTypingToken = nil
        pauseTask?.cancel(); pauseTask = nil
    }

    private func progress(_ token: WordMonitor.Token) {
        if token.liveConverted { cancelTypingTask(); updateLiveReceipt(token); return }
        receipt = nil
        pendingTypingToken = token
        pauseTask?.cancel(); pauseTask = nil
        if (2...3).contains(token.text.count) {
            let task = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.pauseTask = nil
                self.process(token, whileTyping: true, paused: true)
            }
            pauseTask = task
            queue.asyncAfter(deadline: .now() + 0.6, execute: task)
        }
        guard typingTask == nil, token.text.count >= 4 else { return }
        let task = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.typingTask = nil
            guard let latest = self.pendingTypingToken else { return }
            self.pendingTypingToken = nil
            self.process(latest, whileTyping: true)
        }
        typingTask = task
        queue.asyncAfter(deadline: .now() + 0.035, execute: task)
    }

    private func updateLiveReceipt(_ token: WordMonitor.Token) {
        guard !token.text.isEmpty else { receipt = nil; return }
        guard let previous = receipt, previous.live, previous.cycle == nil, previous.app == token.app,
              previous.layoutID == token.sourceID,
              let origin = layouts.first(where: { $0.id == previous.sourceID }),
              let current = layouts.first(where: { $0.id == token.sourceID }) else { return }
        let original: String
        if token.text.hasPrefix(previous.replacement),
           let tail = current.convert(String(token.text.dropFirst(previous.replacement.count)), to: origin) {
            original = previous.original + tail
        } else if previous.replacement.hasPrefix(token.text), previous.original.count == previous.replacement.count {
            original = String(previous.original.prefix(token.text.count))
        } else { receipt = nil; return }
        receipt = Receipt(original: original, replacement: token.text, sourceID: previous.sourceID,
                          layoutID: previous.layoutID, cycle: nil, live: true, app: previous.app)
    }

    private func request(for token: WordMonitor.Token, source: KeyboardLayout, whileTyping: Bool, paused: Bool = false) -> CorrectionRequest {
        let values = settings.values
        return CorrectionRequest(text: token.text, source: source, layouts: layouts, ignored: ignored,
                                 preferredTargetID: values.preferredLayouts[token.app] ?? values.lastManualCyrillic,
                                 correctSpelling: values.correctSpelling, whileTyping: whileTyping,
                                 liveConverted: token.liveConverted, paused: paused)
    }

    private func process(_ token: WordMonitor.Token, whileTyping: Bool = false, paused: Bool = false) {
        if !whileTyping { cancelTypingTask() }
        if token.liveConverted {
            updateLiveReceipt(token)
            if whileTyping || !settings.values.correctSpelling { return }
        } else { receipt = nil }
        guard monitor.enabled, monitor.revision == token.revision,
              let source = layouts.first(where: { $0.id == token.sourceID }) else { return }
        guard whileTyping else { correct(token, whileTyping: false); return }
        let request = self.request(for: token, source: source, whileTyping: true, paused: paused)
        worker.async { [self] in
            guard monitor.revision == token.revision, detector.mayCorrect(request) else { return }
            queue.async { self.correct(token, whileTyping: true, paused: paused) }
        }
    }

    private func correct(_ token: WordMonitor.Token, whileTyping: Bool, paused: Bool = false) {
        guard monitor.enabled, monitor.revision == token.revision,
              let source = layouts.first(where: { $0.id == token.sourceID }) else { return }
        let request = self.request(for: token, source: source, whileTyping: whileTyping, paused: paused)
        guard detectorLoaded, hub.beginGate(revision: token.revision) else { return }
        worker.async { [self] in
            defer { queue.async { self.hub.endGate(revision: token.revision) } }
            guard hub.revision == token.revision else { return }
            guard whileTyping || detector.mayCorrect(request) else { return }
            guard let suggestion = detector.correction(request, context: ""),
                  let edit = Self.keystrokeEdit(for: token, suggestion: suggestion, source: source),
                  hub.revision == token.revision, !secureInput,
                  hub.commitGate(revision: token.revision) else { return }
            let typed = type(edit, typed: token.text, suffix: token.suffix, from: source, in: suggestion.target)
            queue.sync {
                self.handle(typed, original: token.text, replacement: suggestion.replacement, sourceID: source.id,
                            target: suggestion.target, live: whileTyping, keystrokeSuffix: token.suffix, app: token.app)
            }
        }
    }

    /// As AppModel.keystrokeEdit in its blind mode: only layout changes are typed, and a lone
    /// letter (a shortcut on a canvas, a shell command) is converted only by Shift.
    static func keystrokeEdit(for token: WordMonitor.Token, suggestion: Suggestion, source: KeyboardLayout) -> KeystrokeEdit? {
        guard suggestion.target.id != source.id, token.text.count > 1 else { return nil }
        return KeystrokeEdit(typed: token.text, replacement: suggestion.replacement, suffix: token.suffix)
    }

    /// Worker, inside a committed gate. Erases, selects the target layout and presses the
    /// replacement with its keys. If the layout cannot be selected, the erased text is typed back.
    func type(_ edit: KeystrokeEdit, typed: String, suffix: String, from origin: KeyboardLayout, in target: KeyboardLayout) -> Bool {
        let caps = hub.capsLock
        let strokes = edit.insertion.compactMap { Self.stroke(for: $0, in: target, capsLock: caps) }
        let common = typed.count + suffix.count - edit.deletions
        let erased = String((typed + suffix).dropFirst(max(common, 0)))
        let restore = erased.compactMap { Self.stroke(for: $0, in: origin, capsLock: caps) }
        trace("type: erase \(edit.deletions) of \(typed.debugDescription)+\(suffix.debugDescription), insert \(edit.insertion.debugDescription) in \(target.id), current \(currentIDSafe())")
        guard strokes.count == edit.insertion.count else { return false }
        typist.settle()
        typist.erase(edit.deletions)
        hub.progress()
        var selected = false
        queue.sync { selected = self.currentID() == target.id || self.selectLayout(target) }
        hub.progress()
        trace("type: selected \(selected), now \(currentIDSafe())")
        guard selected else {
            if restore.count == erased.count { typist.press(restore) }
            return false
        }
        typist.pause()
        typist.press(strokes)
        hub.progress()
        return true
    }

    /// The key and Shift state that type this character with Caps Lock as it is now.
    static func stroke(for character: Character, in layout: KeyboardLayout, capsLock: Bool) -> KeyboardLayout.KeyStroke? {
        guard let stroke = layout.stroke(for: character) else { return nil }
        guard capsLock else { return stroke }
        for shift in [stroke.shift, !stroke.shift] where layout.character(key: stroke.key, shift: shift, capsLock: true) == String(character) {
            return KeyboardLayout.KeyStroke(key: stroke.key, shift: shift, capsLock: true)
        }
        return stroke
    }

    private func handle(_ success: Bool, original: String, replacement: String, sourceID: String, target: KeyboardLayout,
                        cycle: LayoutCycle? = nil, live: Bool = false, physicalKeys: [KeyboardLayout.KeyStroke]? = nil,
                        keystrokeSuffix: String, app: String) {
        guard success else { setDetail("Не удалось переключить раскладку для замены."); return }
        if !live { monitor.reset() }
        corrections += 1
        receipt = Receipt(original: original, replacement: replacement, sourceID: sourceID, layoutID: target.id, cycle: cycle,
                          live: live, physicalKeys: physicalKeys, keystrokes: (keystrokeSuffix, monitor.revision), app: app)
        if cycle != nil {
            guard selectManually(target, app: app) else { return }
        } else if currentID() != target.id, !selectLayout(target) {
            setDetail("Текст исправлен, но раскладку переключить не удалось."); return
        }
        if live { monitor.resumeAfterLiveCorrection(text: replacement, sourceID: target.id, app: app) }
        receipt?.keystrokes?.revision = monitor.revision
        setDetail(cycle == nil ? "Исправлено. Короткий Shift — отменить." : "Раскладка: \(target.name). Ещё короткий Shift — следующий язык.")
    }

    @discardableResult private func selectManually(_ target: KeyboardLayout, app: String) -> Bool {
        guard currentID() == target.id || selectLayout(target) else {
            setDetail("Не удалось включить раскладку \(target.name)."); return false
        }
        if target.languages.contains(.russian) || target.languages.contains(.ukrainian) {
            settings.update { values in
                if !app.isEmpty { values.preferredLayouts[app] = target.id }
                values.lastManualCyrillic = target.id
            }
        }
        return true
    }

    private func switchLayoutOnly(sourceID: String, app: String) {
        let ordered = KeyboardLayout.cycleOrder(layouts)
        let cycle = LayoutCycle(layoutIDs: ordered.map(\.id))
        guard let nextID = cycle.next(after: sourceID), let target = ordered.first(where: { $0.id == nextID }) else { return }
        receipt = nil
        if selectManually(target, app: app) { setDetail("Раскладка: \(target.name).") }
    }

    // MARK: Shift

    private func manual(after expectedToken: WordMonitor.Token?) {
        trace("shift: token \(expectedToken?.text.debugDescription ?? "nil") suffix \(expectedToken?.suffix.debugDescription ?? "nil"), receipt \(receipt.map { "\($0.original)->\($0.replacement)" } ?? "nil"), enabled \(monitor.enabled)")
        cancelTypingTask()
        guard monitor.enabled else { return }
        sourceChanged()
        let revision = monitor.revision, layouts = self.layouts, receipt = self.receipt
        let sourceID = currentID()
        let app = activeApp?.id ?? ""
        let preferredID = settings.values.preferredLayouts[app] ?? settings.values.lastManualCyrillic
        guard hub.beginGate(revision: revision) else { trace("shift: gate refused"); return }
        worker.async { [self] in
            defer { queue.async { self.hub.endGate(revision: revision) } }
            if !manualByKeystrokes(expectedToken: expectedToken, receipt: receipt, revision: revision, sourceID: sourceID,
                                   layouts: layouts, preferredID: preferredID, app: app), expectedToken == nil {
                queue.sync {
                    guard self.monitor.revision == revision, self.monitor.enabled, !self.secureInput else { return }
                    self.switchLayoutOnly(sourceID: sourceID, app: app)
                }
            }
        }
    }

    /// Worker, inside the gate: AppModel.manualByKeystrokes. Undo or cycle the last edit while
    /// nothing was typed since, else convert the word just typed. False: nothing to convert.
    private func manualByKeystrokes(expectedToken: WordMonitor.Token?, receipt: Receipt?, revision: UInt64, sourceID: String,
                                    layouts: [KeyboardLayout], preferredID: String?, app: String) -> Bool {
        func type(_ edit: KeystrokeEdit?, typed: String, suffix: String, from origin: KeyboardLayout, in layout: KeyboardLayout) -> Bool {
            guard let edit, hub.revision == revision, !secureInput, hub.commitGate(revision: revision) else {
                trace("shift: no edit \(edit == nil) revision \(hub.revision) vs \(revision)"); return false
            }
            return self.type(edit, typed: typed, suffix: suffix, from: origin, in: layout)
        }
        let current = layouts.first(where: { $0.id == sourceID })
        if let receipt, let keystrokes = receipt.keystrokes, receipt.app == app,
           expectedToken.map({ [receipt.original, receipt.replacement].contains($0.text) }) ?? (revision == keystrokes.revision &+ 1) {
            let suffix = expectedToken?.suffix ?? keystrokes.suffix
            guard let origin = layouts.first(where: { $0.id == receipt.sourceID }), let current else { return true }
            if let cycle = receipt.cycle {
                guard sourceID == receipt.layoutID, let nextID = cycle.next(after: sourceID),
                      let target = layouts.first(where: { $0.id == nextID }),
                      let converted = target.id == origin.id ? receipt.original
                          : detector.convertTextManually(receipt.original, source: origin, target: target, physicalKeys: receipt.physicalKeys),
                      type(KeystrokeEdit(typed: receipt.replacement, replacement: converted, suffix: suffix),
                           typed: receipt.replacement, suffix: suffix, from: current, in: target) else { return true }
                queue.sync {
                    self.handle(true, original: receipt.original, replacement: converted, sourceID: receipt.sourceID, target: target,
                                cycle: cycle, physicalKeys: receipt.physicalKeys, keystrokeSuffix: suffix, app: app)
                }
                return true
            }
            guard type(KeystrokeEdit(typed: receipt.replacement, replacement: receipt.original, suffix: suffix),
                       typed: receipt.replacement, suffix: suffix, from: current, in: origin) else { return true }
            queue.sync {
                let compatible = KeyboardLayout.cycleOrder(layouts).filter { origin.convert(receipt.original, to: $0) != nil }
                self.receipt = Receipt(original: receipt.original, replacement: receipt.original, sourceID: receipt.sourceID,
                                       layoutID: receipt.sourceID, cycle: LayoutCycle(layoutIDs: compatible.map(\.id)),
                                       keystrokes: (suffix, self.monitor.revision), app: app)
                _ = self.selectManually(origin, app: app)
                if receipt.live, suffix.isEmpty {
                    self.monitor.resumeAfterLiveCorrection(text: receipt.original, sourceID: origin.id, app: app)
                }
                self.receipt?.keystrokes?.revision = self.monitor.revision
                self.setDetail("Замена отменена.")
            }
            return true
        }
        guard let token = expectedToken, token.app == app, token.sourceID == sourceID, !token.text.isEmpty,
              let source = current else { return expectedToken != nil }
        guard let candidate = detector.convertManually(token.text, source: source, layouts: layouts,
                                                       preferredTargetID: preferredID, physicalKeys: token.physicalKeys),
              type(KeystrokeEdit(typed: token.text, replacement: candidate.replacement, suffix: token.suffix),
                   typed: token.text, suffix: token.suffix, from: source, in: candidate.target) else { return true }
        let compatible = KeyboardLayout.cycleOrder(layouts).filter { source.convert(token.text, to: $0) != nil }
        let cycle = LayoutCycle(layoutIDs: compatible.map(\.id), startingID: sourceID, firstTargetID: candidate.target.id)
        queue.sync {
            self.handle(true, original: token.text, replacement: candidate.replacement, sourceID: sourceID, target: candidate.target,
                        cycle: cycle, physicalKeys: token.physicalKeys, keystrokeSuffix: token.suffix, app: app)
        }
        return true
    }

    // MARK: State

    /// Engine queue. Applies settings and the desktop state to the monitor.
    public func apply(allowed: Bool) {
        self.allowed = allowed
        let app = activeApp?.id ?? ""
        let excluded = settings.isExcluded(app)
        let enabled = allowed && settings.values.enabled && !secureInput && !excluded && layouts.count >= 2 && !hub.isFaulted
        monitor.enabled = enabled
        hub.lock.lock(); hub.accepting = enabled; hub.lock.unlock()
    }

    public func refreshApp() { _ = lookupApp() }
    public var currentAppID: String { activeApp?.id ?? "" }
    public var currentAppName: String { activeApp?.name ?? "" }
}
