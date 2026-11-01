import Foundation
import os

/// Timings of the steps that decide whether a word gets corrected, for
/// `log stream --level info --predicate 'subsystem == "local.yasno.switcher"'`.
/// Only pids, counts and durations are logged, never what was typed.
enum Trace {
    /// Application activation, focus notifications and the state of the monitor.
    static let switching = Logger(subsystem: "local.yasno.switcher", category: "switching")
    /// The Accessibility steps of one correction attempt.
    static let correction = Logger(subsystem: "local.yasno.switcher", category: "correction")

    static func milliseconds(since start: TimeInterval) -> Int {
        Int((ProcessInfo.processInfo.systemUptime - start) * 1000)
    }
}
