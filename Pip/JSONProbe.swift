import Foundation

/// Defensive helpers for poking at JSON whose schema we don't fully trust.
/// Everything here returns nil instead of throwing.
enum JSONProbe {

    static func parse(_ data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Depth-first search for the first String value stored under any of `keys`
    /// (case-insensitive), anywhere in the tree.
    static func firstString(in object: Any, keys: [String]) -> String? {
        let wanted = Set(keys.map { $0.lowercased() })
        var found: String?
        walk(object, path: []) { dict, _ in
            guard found == nil else { return }
            for (k, v) in dict {
                if wanted.contains(k.lowercased()), let s = v as? String, !s.isEmpty {
                    found = s
                    return
                }
            }
        }
        return found
    }

    /// Accepts UNIX epoch seconds (or milliseconds), numeric strings, and
    /// ISO-8601 strings with or without fractional seconds.
    static func parseDate(_ value: Any) -> Date? {
        if let n = value as? NSNumber {
            return epochDate(n.doubleValue)
        }
        if let s = value as? String {
            if let d = Double(s) { return epochDate(d) }
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFrac.date(from: s) { return d }
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
        return nil
    }

    // MARK: - Internals

    private static func epochDate(_ d: Double) -> Date? {
        guard d > 0 else { return nil }
        return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
    }

    private static func walk(_ object: Any, path: [String], visit: ([String: Any], [String]) -> Void) {
        if let dict = object as? [String: Any] {
            visit(dict, path)
            for (k, v) in dict { walk(v, path: path + [k], visit: visit) }
        } else if let array = object as? [Any] {
            for (i, v) in array.enumerated() { walk(v, path: path + ["\(i)"], visit: visit) }
        }
    }
}
