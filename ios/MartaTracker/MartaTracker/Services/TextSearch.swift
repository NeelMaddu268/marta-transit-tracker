import Foundation

extension String {
    /// Normalized form for forgiving search: lowercased, "&" treated as "and",
    /// punctuation flattened to spaces, and whitespace collapsed. So
    /// "Windward Park & Ride" and "windward park and ride" compare equal.
    var searchNormalized: String {
        let lowered = lowercased().replacingOccurrences(of: "&", with: " and ")
        let flattened = lowered.unicodeScalars.map {
            CharacterSet.alphanumerics.contains($0) ? Character($0) : " "
        }
        return String(flattened).split(separator: " ").joined(separator: " ")
    }

    /// True if this string contains `query` after both are normalized. An empty
    /// query matches everything.
    func searchMatches(_ query: String) -> Bool {
        let q = query.searchNormalized
        return q.isEmpty || searchNormalized.contains(q)
    }

    /// Strip a bay suffix: "WINDWARD PARK & RIDE - BAY C" -> "WINDWARD PARK & RIDE".
    var baseStopName: String {
        replacingOccurrences(of: #"\s*-\s*BAY\s+[A-Z0-9]+\s*$"#,
                             with: "", options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }
}
