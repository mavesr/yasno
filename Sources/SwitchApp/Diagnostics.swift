import Cocoa
import Carbon
import os

/// Input diagnostics. While a session is on, Ясно writes down what it decided for each word:
/// which application and field took the keys, the word it saw, what the dictionaries said, and
/// why it changed nothing (no field, no caret, a refused edit). A field where words are not
/// switched can then be fixed from the journal alone. Off by default; nothing is recorded
/// while macOS reports secure input (password fields), and a field that looks like a password
/// field is described without its text.
enum Diagnostics {
    private static let state = OSAllocatedUnfairLock(initialState: false)
    /// Set once by DiagnosticService before the first session starts; called from any thread.
    static var sink: (([String: Any]) -> Void)?
    private static let describer = DispatchQueue(label: "local.yasno.diagnostic-field", qos: .utility)

    /// The focused field looked like a secret one: words typed there go in without their text.
    private static let secretField = OSAllocatedUnfairLock(initialState: false)
    static let textKeys: Set<String> = ["text", "suffix", "replacement", "context_tail", "before_caret", "value_start"]

    static var active: Bool { state.withLock { $0 } }
    static func setActive(_ on: Bool) {
        state.withLock { $0 = on }
        secretField.withLock { $0 = false }
    }

    /// Records one engine event. The fields are built only while a session is on.
    static func note(_ event: String, _ fields: @autoclosure () -> [String: Any] = [:]) {
        guard active, !IsSecureEventInputEnabled(), let sink else { return }
        var row = redacted(fields(), secret: secretField.withLock { $0 })
        row["event"] = event
        row["uptime_ms"] = Int(ProcessInfo.processInfo.systemUptime * 1000)
        sink(row)
    }

    /// Describes a field off the caller's thread (main must never wait on another application).
    static func noteField(_ event: String, element: AXUIElement, pid: pid_t, extra: [String: Any] = [:]) {
        guard active else { return }
        describer.async {
            guard active else { return }
            var fields = extra
            let field = describe(element)
            if event == "focus" { secretField.withLock { $0 = field["text"] != nil } }
            fields["field"] = field
            fields["app"] = application(pid)
            note(event, fields)
        }
    }

    /// Typed text replaced by a marker while the focused field may hold a secret.
    static func redacted(_ fields: [String: Any], secret: Bool) -> [String: Any] {
        guard secret else { return fields }
        var out = fields
        for key in textKeys where out[key] != nil { out[key] = "not recorded: field may hold a secret" }
        return out
    }

    /// Why no field was found: which application macOS sends keys to, and what the system-wide
    /// and the application's own focused elements are. Off the caller's thread.
    static func noteFocusLookup(_ event: String, pid: pid_t, extra: [String: Any] = [:]) {
        guard active else { return }
        describer.async {
            guard active else { return }
            var fields = extra
            fields["app"] = application(pid)
            fields["typing_app_pid"] = Int(AccessibleEditor.typingApplication()?.processIdentifier ?? 0)
            func focused(_ root: AXUIElement) -> (AXError, AXUIElement?) {
                AXUIElementSetMessagingTimeout(root, 0.12)
                let (status, value) = attribute(root, kAXFocusedUIElementAttribute)
                guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return (status, nil) }
                return (status, unsafeBitCast(value, to: AXUIElement.self))
            }
            let (systemStatus, system) = focused(AXUIElementCreateSystemWide())
            if let system {
                var owner: pid_t = 0
                AXUIElementGetPid(system, &owner)
                fields["system_focus_pid"] = Int(owner)
                fields["system_focus"] = describe(system)
            } else { fields["system_focus"] = "error \(systemStatus.rawValue)" }
            let (appStatus, local) = focused(AXUIElementCreateApplication(pid))
            if let local { fields["app_focus"] = describe(local) } else { fields["app_focus"] = "error \(appStatus.rawValue)" }
            note(event, fields)
        }
    }

    static func application(_ pid: pid_t) -> [String: Any] {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return ["pid": Int(pid)] }
        let version = app.bundleURL.flatMap { Bundle(url: $0) }?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        return ["pid": Int(pid), "bundle_id": app.bundleIdentifier ?? "", "name": app.localizedName ?? "",
                "version": version]
    }

    private static func attribute(_ element: AXUIElement, _ name: String) -> (AXError, CFTypeRef?) {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return (result, value)
    }

    private static func string(_ element: AXUIElement, _ name: String, limit: Int = 120) -> String? {
        guard case (.success, let value?) = attribute(element, name), let text = value as? String else { return nil }
        return String(text.prefix(limit))
    }

    private static func range(_ value: CFTypeRef?) -> CFRange? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        return AXValueGetValue(unsafeBitCast(value, to: AXValue.self), .cfRange, &range) ? range : nil
    }

    /// Whether a field's text may go into the journal: never a password field, never one that
    /// says its content is protected, never when the security state cannot be read.
    static func mayRecordText(subrole: String?, protectedStatus: AXError, protected: Bool?,
                              names: [String]) -> Bool {
        let secret = ["secure", "pass", "secret", "token", "otp", "pin-code", "credential"]
        let all = ([subrole ?? ""] + names).map { $0.lowercased() }
        if all.contains(where: { name in secret.contains { name.contains($0) } }) { return false }
        switch protectedStatus {
        case .success: return protected == false
        case .attributeUnsupported, .noValue: return true
        default: return false
        }
    }

    /// What Accessibility shows of a field: roles up the tree, what can be read and set, the
    /// selection, and up to 80 characters before the caret when the field is not a secret one.
    static func describe(_ element: AXUIElement) -> [String: Any] {
        AXUIElementSetMessagingTimeout(element, 0.12)
        var out: [String: Any] = [:]
        let (roleStatus, role) = attribute(element, kAXRoleAttribute)
        out["role"] = role as? String ?? "error \(roleStatus.rawValue)"
        let subrole = string(element, kAXSubroleAttribute)
        if let subrole { out["subrole"] = subrole }
        for (key, name) in [("role_description", kAXRoleDescriptionAttribute), ("identifier", kAXIdentifierAttribute),
                            ("dom_identifier", "AXDOMIdentifier"), ("placeholder", kAXPlaceholderValueAttribute),
                            ("title", kAXTitleAttribute), ("description", kAXDescriptionAttribute)] {
            if let value = string(element, name, limit: 80), !value.isEmpty { out[key] = value }
        }
        let classes = (attribute(element, "AXDOMClassList").1 as? [String])?.prefix(8).map { String($0.prefix(60)) } ?? []
        if !classes.isEmpty { out["dom_classes"] = classes }
        var names: CFArray?
        if AXUIElementCopyAttributeNames(element, &names) == .success, let list = names as? [String] {
            out["attributes"] = list.sorted()
        }
        var settable: [String] = []
        for name in [kAXValueAttribute, kAXSelectedTextAttribute, kAXSelectedTextRangeAttribute] {
            var flag = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(element, name as CFString, &flag) == .success, flag.boolValue {
                settable.append(name)
            }
        }
        out["settable"] = settable
        let (countStatus, count) = attribute(element, kAXNumberOfCharactersAttribute)
        out["characters"] = (count as? Int) ?? "error \(countStatus.rawValue)"
        let (selectionStatus, selectionValue) = attribute(element, kAXSelectedTextRangeAttribute)
        let selection = range(selectionValue)
        out["selection"] = selection.map { ["location": $0.location, "length": $0.length] } ?? "error \(selectionStatus.rawValue)"
        // Ancestors: a web field often sits in groups inside an AXWebArea.
        var ancestors: [String] = []
        var node = element
        for _ in 0..<8 {
            guard case (.success, let parent?) = attribute(node, kAXParentAttribute),
                  CFGetTypeID(parent) == AXUIElementGetTypeID() else { break }
            node = unsafeBitCast(parent, to: AXUIElement.self)
            let role = string(node, kAXRoleAttribute) ?? "?"
            let sub = string(node, kAXSubroleAttribute).map { ":" + $0 } ?? ""
            ancestors.append(role + sub)
        }
        out["ancestors"] = ancestors
        let (protectedStatus, protected) = attribute(element, "AXProtectedContent")
        guard mayRecordText(subrole: subrole, protectedStatus: protectedStatus, protected: protected as? Bool,
                            names: classes + ancestors + [out["identifier"] as? String ?? ""]) else {
            out["text"] = "not recorded: field may hold a secret"
            return out
        }
        if let selection, selection.location > 0 {
            let start = max(0, selection.location - 80)
            var raw = CFRange(location: start, length: selection.location - start)
            if let value = AXValueCreate(.cfRange, &raw) {
                var text: CFTypeRef?
                let status = AXUIElementCopyParameterizedAttributeValue(
                    element, kAXStringForRangeParameterizedAttribute as CFString, value, &text)
                out["before_caret"] = (text as? String) ?? "error \(status.rawValue)"
            }
        } else if let value = string(element, kAXValueAttribute, limit: 80) {
            out["value_start"] = value
        }
        return out
    }
}
