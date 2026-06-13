import Foundation

/// Defensive helpers for poking at JSON whose schema we don't fully trust
/// (the OAuth usage endpoint is undocumented; the statusline payload is
/// versioned by Claude Code). Everything here returns nil instead of throwing.
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

    /// Extract the canonical usage snapshot from either the OAuth payload or a
    /// statusline `rate_limits` payload. Tries well-known paths first, then
    /// falls back to a heuristic walk. Returns nil if nothing usable was found.
    static func extractUsage(from object: Any) -> UsageSnapshot? {
        var snap = UsageSnapshot()

        // 1. Well-known container paths, most specific first.
        let roots: [Any] = [
            (object as? [String: Any])?["rate_limits"] as Any,
            (object as? [String: Any])?["usage"] as Any,
            object,
        ]
        for root in roots {
            guard let dict = root as? [String: Any] else { continue }
            if let five = windowDict(dict, keys: ["five_hour", "fiveHour", "5h", "session"]) {
                apply(five, fiveHour: true, to: &snap)
            }
            if let week = windowDict(dict, keys: ["seven_day", "sevenDay", "7d", "weekly", "week"]) {
                apply(week, fiveHour: false, to: &snap)
            }
        }

        // 2. Heuristic fallback: walk the whole tree for dicts that look like a
        //    usage window, classifying them by their key path. Never overwrites
        //    a field already found, and skips model-specific buckets ("opus").
        if snap.fiveHourUsedPct == nil || snap.weeklyUsedPct == nil {
            walk(object, path: []) { dict, path in
                let joined = path.joined(separator: "/").lowercased()
                guard !joined.contains("opus") else { return }
                let pct = number(in: dict, keys: percentKeys)
                let reset = value(in: dict, keys: resetKeys)
                guard pct != nil || reset != nil else { return }

                let isFive = joined.contains("five") || joined.contains("5h") || joined.contains("5_h")
                let isWeek = joined.contains("seven") || joined.contains("7d") || joined.contains("week")
                if isFive {
                    if snap.fiveHourUsedPct == nil, let p = pct { snap.fiveHourUsedPct = clampPct(p) }
                    if snap.fiveHourResetsAt == nil, let r = reset { snap.fiveHourResetsAt = parseDate(r) }
                } else if isWeek {
                    if snap.weeklyUsedPct == nil, let p = pct { snap.weeklyUsedPct = clampPct(p) }
                    if snap.weeklyResetsAt == nil, let r = reset { snap.weeklyResetsAt = parseDate(r) }
                }
            }
        }

        if snap.fiveHourUsedPct == nil && snap.weeklyUsedPct == nil { return nil }
        return snap
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

    private static let percentKeys = [
        "used_percentage", "utilization", "used_pct", "usage_percentage", "percent_used", "usedpercentage",
    ]
    private static let resetKeys = [
        "resets_at", "reset_at", "resets", "reset_time", "resetsat", "resetat",
    ]

    private static func epochDate(_ d: Double) -> Date? {
        guard d > 0 else { return nil }
        return Date(timeIntervalSince1970: d > 1e12 ? d / 1000 : d)
    }

    private static func clampPct(_ p: Double) -> Double { min(100, max(0, p)) }

    private static func windowDict(_ dict: [String: Any], keys: [String]) -> [String: Any]? {
        for key in keys {
            for (k, v) in dict where k.lowercased() == key.lowercased() {
                if let d = v as? [String: Any] { return d }
            }
        }
        return nil
    }

    private static func apply(_ window: [String: Any], fiveHour: Bool, to snap: inout UsageSnapshot) {
        let pct = number(in: window, keys: percentKeys)
        let reset = value(in: window, keys: resetKeys).flatMap(parseDate)
        if fiveHour {
            if snap.fiveHourUsedPct == nil, let p = pct { snap.fiveHourUsedPct = clampPct(p) }
            if snap.fiveHourResetsAt == nil { snap.fiveHourResetsAt = reset }
        } else {
            if snap.weeklyUsedPct == nil, let p = pct { snap.weeklyUsedPct = clampPct(p) }
            if snap.weeklyResetsAt == nil { snap.weeklyResetsAt = reset }
        }
    }

    private static func number(in dict: [String: Any], keys: [String]) -> Double? {
        if let v = value(in: dict, keys: keys) {
            if let n = v as? NSNumber { return n.doubleValue }
            if let s = v as? String { return Double(s) }
        }
        return nil
    }

    private static func value(in dict: [String: Any], keys: [String]) -> Any? {
        let wanted = Set(keys.map { $0.lowercased() })
        for (k, v) in dict where wanted.contains(k.lowercased()) {
            if v is NSNull { continue }
            return v
        }
        return nil
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
