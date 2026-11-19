import Foundation
import SwitchCore

/// The word being typed, built from observed keys: a port of KeyboardMonitor.receive on the
/// Mac, with the same rules for Space, Backspace, Tab, Enter, dead keys and the Shift tap.
/// Engine queue only.
public final class WordMonitor {
    public struct Token: Equatable {
        public let text: String
        public let suffix: String
        public let sourceID: String
        public let app: String
        public let revision: UInt64
        public var liveConverted = false
        public var physicalKeys: [KeyboardLayout.KeyStroke]? = nil
    }

    var onToken: ((Token) -> Void)?
    var onProgress: ((Token) -> Void)?
    var onManual: ((Token?) -> Void)?
    var onCancelAnalysis: (() -> Void)?

    let hub: InputHub
    var layouts: [KeyboardLayout] = []
    var enabled = false { didSet { if oldValue && !enabled { reset() } } }
    var currentSourceID: () -> String = { "" }
    var currentApp: () -> String = { "" }
    /// A key starts a word: the engine looks up the application now (it may be one that is
    /// excluded, or the user just left one), so the first letter is judged in the right place.
    var onWordStart: (() -> Void)?
    var secureInput: () -> Bool = { false }

    private(set) var token = ""
    private var physicalKeys: [KeyboardLayout.KeyStroke]? = []
    private var completedToken: Token?
    private var liveConverted = false
    private var composing = false
    private(set) var sourceID = ""
    private(set) var app = ""
    private var shiftGesture = ShiftTapGesture()
    private var held: Set<UInt16> = []

    init(hub: InputHub) { self.hub = hub }

    var revision: UInt64 { hub.revision }
    var pendingCount: Int { token.count }

    func syncSource(_ id: String) {
        guard sourceID != id else { return }
        reset(reason: "layout changed", ["new_layout": id]); sourceID = id
    }

    func syncApplication(_ id: String) {
        guard app != id else { return }
        reset(reason: "application changed", ["new_app": id]); app = id
    }

    /// The word being typed is given up; the journal says why.
    private func drop(_ reason: String, _ extra: [String: Any] = [:]) {
        guard !token.isEmpty else { return }
        Diagnostics.note("word_dropped", ["reason": reason, "text": token, "layout": sourceID, "app": app]
            .merging(extra) { _, new in new })
    }

    func reset(reason: String = "reset", _ extra: [String: Any] = [:]) {
        drop(reason, extra)
        _ = hub.bump()
        token = ""; physicalKeys = []; completedToken = nil; liveConverted = false; composing = false; shiftGesture.reset()
        onCancelAnalysis?()
    }

    func resumeAfterLiveCorrection(text: String, sourceID: String, app: String) {
        self.sourceID = sourceID; self.app = app
        token = text; completedToken = nil; liveConverted = true
        physicalKeys = nil
    }

    private func snapshot(suffix: String = "", revision: UInt64) -> Token {
        Token(text: token, suffix: suffix, sourceID: sourceID, app: app, revision: revision,
              liveConverted: liveConverted, physicalKeys: physicalKeys)
    }

    private var clean: Bool {
        held.isDisjoint(with: [KeyCodes.leftCtrl, KeyCodes.rightCtrl, KeyCodes.leftAlt, KeyCodes.rightAlt,
                               KeyCodes.leftMeta, KeyCodes.rightMeta])
    }
    private var shift: Bool { held.contains(KeyCodes.leftShift) || held.contains(KeyCodes.rightShift) }

    /// One observed event, in the order the desktop received it.
    func receive(_ event: InputEvent) {
        if event.source == .pointer {
            guard event.isKey else { return }
            if event.value == 1 { reset(reason: "mouse click") } else { shiftGesture.cancel() }
            return
        }
        let code = event.code
        // Modifier state is tracked even while paused, so it is right when typing resumes.
        if KeyCodes.modifiers.contains(code) {
            if event.value == 0 { held.remove(code) } else { held.insert(code) }
        }
        if event.value == 0 && !KeyCodes.modifiers.contains(code) { return }
        let navigation: Set<UInt16> = [KeyCodes.enter, 96, 1, 103, 105, 106, 108]
        // Keys that only end a word never need the desktop's state: no D-Bus call to gnome-shell
        // (whose main thread also draws the frames) for a held key's repeats, Enter, arrows,
        // Escape, Tab or a Ctrl/Alt/Super chord. Backspace and Space still sync: they can
        // reopen the previous word, which must not survive a layout or application change.
        let startsNothing = event.value == 2 || !clean || code == KeyCodes.tab || navigation.contains(code)
        if token.isEmpty, event.value == 1, !KeyCodes.modifiers.contains(code), !startsNothing { onWordStart?() }
        guard enabled, !secureInput() else { reset(reason: "monitoring off or password entry"); return }
        if code == KeyCodes.leftShift || code == KeyCodes.rightShift {
            guard event.value != 2 else { return }
            let key: UInt16 = code == KeyCodes.leftShift ? 56 : 60
            let chord = event.value == 0 && hub.takeShiftChord(event.time)
            if event.value == 1 {
                shiftGesture.press(key: key, at: event.time, clean: clean)
            } else if shiftGesture.release(key: key, at: event.time, clean: clean), !chord {
                let revision = hub.bump()
                let expected = token.isEmpty ? completedToken : snapshot(revision: revision)
                token = ""; physicalKeys = []; completedToken = nil; liveConverted = false
                onManual?(expected)
            }
            return
        }
        if KeyCodes.modifiers.contains(code) {
            // Caps Lock, Ctrl, Alt and Super make a chord; their releases do nothing.
            shiftGesture.cancel(); return
        }
        shiftGesture.cancel()
        if token.isEmpty {
            liveConverted = false
            physicalKeys = []
            if !startsNothing {
                syncSource(currentSourceID())
                syncApplication(currentApp())
            }
        }
        let revision = hub.bump()
        let mac = KeyCodes.evdevToMac[code]
        let previous = completedToken
        if code != KeyCodes.space && !(code == KeyCodes.backspace && clean) { completedToken = nil }
        guard clean else { drop("shortcut with Ctrl, Alt or Super", ["key": Int(code)]); token = ""; physicalKeys = []; onCancelAnalysis?(); return }
        // The desktop repeats a held key itself; the kernel's repeat count is not what the field got.
        if event.value == 2 { drop("held key repeated", ["key": Int(code)]); token = ""; physicalKeys = []; completedToken = nil; onCancelAnalysis?(); return }
        if code == KeyCodes.backspace {
            if !token.isEmpty {
                token.removeLast()
                if physicalKeys?.isEmpty == false { physicalKeys?.removeLast() }
                onProgress?(snapshot(revision: revision))
            } else if let previous {
                if previous.suffix.count > 1 {
                    completedToken = Token(text: previous.text, suffix: String(previous.suffix.dropLast()),
                        sourceID: previous.sourceID, app: previous.app, revision: revision,
                        liveConverted: previous.liveConverted, physicalKeys: previous.physicalKeys)
                } else {
                    completedToken = nil
                    token = previous.text; physicalKeys = previous.physicalKeys; liveConverted = previous.liveConverted
                    onProgress?(snapshot(revision: revision))
                }
            }
            return
        }
        if code == KeyCodes.space || code == KeyCodes.tab || navigation.contains(code) { composing = false }
        if code == KeyCodes.tab, !token.isEmpty {
            let completed = snapshot(revision: revision)
            token = ""; physicalKeys = []; liveConverted = false
            onToken?(completed); return
        }
        if code == KeyCodes.tab || navigation.contains(code) {
            drop("Enter, Escape or an arrow key", ["key": Int(code)])
            token = ""; physicalKeys = []; onCancelAnalysis?(); return
        }
        if code == KeyCodes.space {
            if !token.isEmpty {
                let completed = snapshot(suffix: " ", revision: revision)
                completedToken = completed
                onToken?(completed)
            } else if let previous = completedToken, previous.suffix.count < 8 {
                completedToken = Token(text: previous.text, suffix: previous.suffix + " ", sourceID: previous.sourceID,
                    app: previous.app, revision: revision, liveConverted: previous.liveConverted, physicalKeys: previous.physicalKeys)
            } else { completedToken = nil }
            token = ""; physicalKeys = []; liveConverted = false; return
        }
        let caps = hub.capsLock
        guard let mac, let layout = layouts.first(where: { $0.id == sourceID }),
              let string = layout.character(key: mac, shift: shift, capsLock: caps) else {
            drop("key without a character in the layout", ["key": Int(code), "known_layout": layouts.contains { $0.id == sourceID }])
            token = ""; return
        }
        if composing || layout.isDeadKey(key: mac, shift: shift, capsLock: caps) {
            drop("dead key", ["key": Int(code)])
            composing = true; token = ""; physicalKeys = []; onCancelAnalysis?(); return
        }
        guard !string.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              token.count + string.count <= 512 else { drop("control character or overlong word"); token = ""; return }
        token += string
        physicalKeys?.append(.init(key: mac, shift: shift, capsLock: caps))
        onProgress?(snapshot(revision: revision))
    }
}
