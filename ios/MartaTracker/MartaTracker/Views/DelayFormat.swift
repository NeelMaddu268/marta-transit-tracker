import SwiftUI

/// Shared formatting/coloring for delay values, used across the history views.
enum DelayFormat {
    /// e.g. "on time", "7 min late", "2 min early".
    static func label(_ seconds: Int) -> String {
        if abs(seconds) <= 60 { return "on time" }
        let mins = Int((Double(abs(seconds)) / 60).rounded())
        return seconds > 0 ? "\(mins) min late" : "\(mins) min early"
    }

    static func color(_ seconds: Int) -> Color {
        if seconds > 300 { return .red }
        if seconds > 60 { return .orange }
        if seconds < -60 { return .blue }
        return .green
    }
}
