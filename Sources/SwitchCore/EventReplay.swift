import CoreGraphics

public enum EventReplay {
    /// Use the already prepared down as the source of replay metadata. Safe on the
    /// tap thread: no layout/app lookup, and the physical release time/flags survive.
    public static func matchRelease(_ release: CGEvent, to down: CGEvent, tag: Int64) {
        guard release.type == .keyUp, down.type == .keyDown,
              release.getIntegerValueField(.keyboardEventKeycode) == down.getIntegerValueField(.keyboardEventKeycode),
              let source = CGEventSource(event: down) else { return }
        rebind(release, source: source, tag: tag)
        release.setIntegerValueField(.eventSourceUserData, value: tag)
        var count = 0
        var units = [UniChar](repeating: 0, count: 16)
        down.keyboardGetUnicodeString(maxStringLength: units.count, actualStringLength: &count, unicodeString: &units)
        release.keyboardSetUnicodeString(stringLength: count, unicodeString: units)
    }
    public static func allowLocalInput(_ source: CGEventSource) {
        source.localEventsSuppressionInterval = 0
        let all: CGEventFilterMask = [.permitLocalKeyboardEvents, .permitLocalMouseEvents, .permitSystemDefinedEvents]
        source.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateSuppressionInterval)
        source.setLocalEventsFilterDuringSuppressionState(all, state: .eventSuppressionStateRemoteMouseDrag)
    }
    /// Captured events can retain another process's source metadata. Rebind the source
    /// while preserving physical input state and the original Shift hold timestamps.
    public static func rebind(_ event: CGEvent, source: CGEventSource, tag: Int64) {
        let flags = event.flags, timestamp = event.timestamp, type = event.type
        source.userData = tag
        event.setSource(source)
        event.flags = flags; event.timestamp = timestamp; event.type = type
    }
}
