import Foundation

/// Resolves relative / partial times found in screen text into absolute moments — in code, not in the model.
///
/// A usage panel says "Resets in 4 hr 26 min" or "Resets Sat 12:00 PM". Those are relative to *when the screen was
/// captured*. Language models (small on-device ones especially) routinely get that arithmetic wrong — e.g. attributing
/// the weekly reset time to the session limit — so the evidence the model reads already carries the resolved moment:
///
///     Resets in 4 hr 26 min [= Mon Oct 5, 4:00 PM (already passed)]
public enum AITimeResolver {

    public static func annotate(
        _ text: String,
        capturedAt: Date,
        now: Date,
        calendar: Calendar = .current,
        timeZone: TimeZone = .current
    ) -> String {
        var cal = calendar
        cal.timeZone = timeZone
        let ns = text as NSString
        var edits: [(end: Int, note: String)] = []
        var consumed: [NSRange] = []

        func overlaps(_ r: NSRange) -> Bool { consumed.contains { NSIntersectionRange($0, r).length > 0 } }

        // 1. "<verb> in 4 hr 26 min"
        let verbs = "resets?|renews?|refreshes|refreshing|expires?|ends?|available|ready|unlocks?|starts?"
        let relPattern = #"(?i)\b(?:\#(verbs))\s+in\s+((?:\d+\s*(?:days?|d|hours?|hrs?|hr|h|minutes?|mins?|min|m)\b[\s,]*(?:and\s+)?){1,3})"#
        if let re = try? NSRegularExpression(pattern: relPattern) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let seconds = durationSeconds(ns.substring(with: m.range(at: 1)))
                guard seconds > 0 else { continue }
                let target = capturedAt.addingTimeInterval(seconds)
                // The duration group swallows trailing spaces/commas; put the note right after the last unit.
                let matched = ns.substring(with: m.range) as NSString
                var trimmed = matched.length
                while trimmed > 0, let u = UnicodeScalar(matched.character(at: trimmed - 1)), CharacterSet(charactersIn: " ,\t\n").contains(u) { trimmed -= 1 }
                edits.append((m.range.location + trimmed, describe(target, now: now, cal: cal, timeZone: timeZone)))
                consumed.append(m.range)
            }
        }

        // 2. "<verb> Sat 12:00 PM"
        let dayPattern = #"(?i)\b(?:\#(verbs)|until|by|due)\s+(?:on\s+|at\s+)?(mon|tue|tues|wed|thu|thur|thurs|fri|sat|sun)[a-z]*\.?,?\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#
        if let re = try? NSRegularExpression(pattern: dayPattern) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where !overlaps(m.range) {
                guard let weekday = weekdayNumber(ns.substring(with: m.range(at: 1))),
                      let target = nextOccurrence(weekday: weekday, hour: ns.substring(with: m.range(at: 2)), minute: group(ns, m, 3),
                                                  meridiem: ns.substring(with: m.range(at: 4)), after: capturedAt, cal: cal) else { continue }
                edits.append((m.range.location + m.range.length, describe(target, now: now, cal: cal, timeZone: timeZone)))
                consumed.append(m.range)
            }
        }

        // 3. "<verb> at 4:00 PM" / "resets 1pm"
        let clockPattern = #"(?i)\b(?:\#(verbs)|until|by|due)\s+(?:at\s+)?(\d{1,2})(?::(\d{2}))?\s*(am|pm)\b"#
        if let re = try? NSRegularExpression(pattern: clockPattern) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where !overlaps(m.range) {
                guard let target = nextOccurrence(weekday: nil, hour: ns.substring(with: m.range(at: 1)), minute: group(ns, m, 2),
                                                  meridiem: ns.substring(with: m.range(at: 3)), after: capturedAt, cal: cal) else { continue }
                edits.append((m.range.location + m.range.length, describe(target, now: now, cal: cal, timeZone: timeZone)))
                consumed.append(m.range)
            }
        }

        // 4. "12 min ago"
        if let re = try? NSRegularExpression(pattern: #"(?i)\b(\d+)\s*(days?|hours?|hrs?|hr|h|minutes?|mins?|min|m)\s+ago\b"#) {
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) where !overlaps(m.range) {
                let seconds = durationSeconds(ns.substring(with: m.range(at: 1)) + " " + ns.substring(with: m.range(at: 2)))
                guard seconds > 0 else { continue }
                let when = capturedAt.addingTimeInterval(-seconds)
                edits.append((m.range.location + m.range.length, " [= \(format(when, cal: cal, timeZone: timeZone))]"))
            }
        }

        // Apply back-to-front so earlier offsets stay valid.
        var result = text
        for edit in edits.sorted(by: { $0.end > $1.end }) {
            let idx = result.index(result.startIndex, offsetBy: edit.end, limitedBy: result.endIndex) ?? result.endIndex
            result.insert(contentsOf: edit.note, at: idx)
        }
        return result
    }

    // MARK: Pieces

    static func durationSeconds(_ text: String) -> TimeInterval {
        guard let re = try? NSRegularExpression(pattern: #"(?i)(\d+)\s*(days?|d|hours?|hrs?|hr|h|minutes?|mins?|min|m)\b"#) else { return 0 }
        let ns = text as NSString
        var total: TimeInterval = 0
        for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let n = Double(ns.substring(with: m.range(at: 1))) ?? 0
            let unit = ns.substring(with: m.range(at: 2)).lowercased()
            if unit.hasPrefix("d") { total += n * 86_400 } else if unit.hasPrefix("h") { total += n * 3_600 } else { total += n * 60 }
        }
        return total
    }

    private static func group(_ ns: NSString, _ m: NSTextCheckingResult, _ i: Int) -> String? {
        let r = m.range(at: i)
        return r.location == NSNotFound ? nil : ns.substring(with: r)
    }

    static func weekdayNumber(_ s: String) -> Int? {   // Calendar: Sunday = 1
        let key = String(s.lowercased().prefix(3))
        return ["sun": 1, "mon": 2, "tue": 3, "wed": 4, "thu": 5, "fri": 6, "sat": 7][key]
    }

    /// First moment at/after `after` that has the given clock time (and weekday, if any).
    static func nextOccurrence(weekday: Int?, hour hourText: String, minute minuteText: String?, meridiem: String, after: Date, cal: Calendar) -> Date? {
        guard var hour = Int(hourText), (1...12).contains(hour) else { return nil }
        let minute = Int(minuteText ?? "0") ?? 0
        let pm = meridiem.lowercased() == "pm"
        if hour == 12 { hour = pm ? 12 : 0 } else if pm { hour += 12 }
        let startOfDay = cal.startOfDay(for: after)
        for offset in 0...7 {
            guard let day = cal.date(byAdding: .day, value: offset, to: startOfDay),
                  let candidate = cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) else { continue }
            if let weekday, cal.component(.weekday, from: candidate) != weekday { continue }
            if candidate >= after { return candidate }
        }
        return nil
    }

    static func format(_ date: Date, cal: Calendar, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.calendar = cal
        f.timeZone = timeZone
        f.dateFormat = "EEE MMM d, h:mm a"
        return f.string(from: date)
    }

    private static func describe(_ target: Date, now: Date, cal: Calendar, timeZone: TimeZone) -> String {
        let when = format(target, cal: cal, timeZone: timeZone)
        let delta = target.timeIntervalSince(now)
        if delta <= 0 { return " [= \(when) (already passed)]" }
        let mins = Int(delta / 60)
        let span = mins >= 1_440 ? "\(mins / 1_440) d \((mins % 1_440) / 60) hr" : (mins >= 60 ? "\(mins / 60) hr \(mins % 60) min" : "\(mins) min")
        return " [= \(when) (still upcoming, in \(span))]"
    }
}
