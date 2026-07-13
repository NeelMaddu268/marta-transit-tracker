import Foundation

/// How much to trust a countdown, from measured feed accuracy (2026-07-13):
/// rail from 7,901 recorded train approaches; bus from a live drift experiment
/// over ~16k tracked predictions. "Typical" ≈ p75 absolute error.
enum ETAConfidence {
    /// Typical error (± minutes) for a prediction this far out.
    static func typicalErrorMinutes(isRail: Bool, horizonMinutes: Int) -> Int {
        switch (isRail, horizonMinutes) {
        case (true, ..<10): return 1     // rail: ±0.5m median, ±1.4m p90
        case (true, ..<20): return 2     // rail: ±0.9m median, ±2.7m p90
        case (true, _):     return 3     // rail 20m+: ±1.1m median, ±3.4m p90
        case (false, ..<10): return 1    // bus near-term: ±0.8m median
        case (false, ..<20): return 2
        case (false, _):     return 3
        }
    }

    /// Far-out predictions get a "~" — they're schedule-anchored estimates that
    /// only firm up as the vehicle approaches.
    static func isApproximate(horizonMinutes: Int) -> Bool {
        horizonMinutes >= 15
    }

    /// A prediction that moved more than this between polls is actively being
    /// re-estimated (traffic, holds) — surface it as "updating".
    static let volatileShiftSeconds = 45
}
