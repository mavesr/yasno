import Foundation

/// Fires only on release of one briefly held Shift that was never used with another input.
/// The actual modifier events always continue to the application without delay.
public struct ShiftTapGesture {
    public static let maximumHold: TimeInterval = 0.4
    private var down: (key: UInt16, time: TimeInterval)?
    private var blockedUntilRelease = false

    public init() {}

    /// A Shift press that a later mouse action could still turn into a chord.
    public var isPressed: Bool { down != nil }

    public mutating func reset() {
        down = nil
        blockedUntilRelease = false
    }

    /// Typing, another modifier, or a mouse action makes this a normal Shift chord.
    public mutating func cancel() {
        if down != nil { blockedUntilRelease = true }
        down = nil
    }

    public mutating func press(key: UInt16, at time: TimeInterval, clean: Bool = true) {
        // Overlapping left/right Shift and duplicate down events must not restart a tap.
        guard clean, time.isFinite, down == nil, !blockedUntilRelease else {
            down = nil
            blockedUntilRelease = true
            return
        }
        down = (key, time)
    }

    /// Call only once all Shift keys are released, including an overlapping two-Shift chord.
    public mutating func release(key: UInt16, at time: TimeInterval, clean: Bool = true) -> Bool {
        let started = down
        let blocked = blockedUntilRelease
        reset()
        guard clean, !blocked, let started, started.key == key, time.isFinite,
              time >= started.time, time - started.time <= Self.maximumHold else { return false }
        return true
    }
}
