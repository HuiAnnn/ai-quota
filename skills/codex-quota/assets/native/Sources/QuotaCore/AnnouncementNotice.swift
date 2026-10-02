import Foundation

public struct ResetTiming: Equatable, Sendable {
    public let date: Date
    public let isDeadline: Bool
    public let isApproximate: Bool

    public var beijingText: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        formatter.dateFormat = "M月d日 HH:mm"
        return "预计 \(formatter.string(from: date))\(isDeadline ? " 前" : isApproximate ? " 左右" : "")（北京时间）"
    }
}

public struct AnnouncementNotice: Identifiable, Sendable {
    public let announcement: ResetAnnouncement
    public let timing: ResetTiming?
    public let isOverdue: Bool
    public var id: String { announcement.id }

    /// Only the newest direct statement for each kind can supply an active promise.
    /// A later completion, delay or ambiguous update suppresses an older promise.
    public static func active(in items: [ResetAnnouncement], now: Date) -> [AnnouncementNotice] {
        var seen = Set<AnnouncementKind>()
        return items.sorted { $0.date > $1.date }.compactMap { item in
            guard item.phase != .observed, item.kind != .unknown,
                  item.date <= now.addingTimeInterval(60), seen.insert(item.kind).inserted,
                  item.currentPhase == .upcoming else { return nil }
            let timing = item.resetTiming
            // A precise forecast stays visible for six hours after its deadline as overdue.
            // Undated promises expire from the banner after a day; history remains available.
            let expires = timing?.date.addingTimeInterval(6 * 3600) ?? item.date.addingTimeInterval(86400)
            guard now <= expires else { return nil }
            return AnnouncementNotice(announcement: item, timing: timing,
                                      isOverdue: timing.map { now > $0.date } ?? false)
        }
    }
}

extension ResetAnnouncement {
    public var resetTiming: ResetTiming? {
        guard currentPhase == .upcoming else { return nil }
        let clauses = Self.clauses(text.lowercased().replacingOccurrences(of: "’", with: "'"))
        // Only a promise clause or its explicit delivery follow-up can provide the time.
        // Account-upgrade cutoffs and unrelated times never enter this parser.
        let candidates = clauses.filter {
            (Self.classify($0, observed: false) == .upcoming && $0.contains("reset")) ||
            ($0.contains("first one will land") && !$0.contains("if ")) ||
            ($0.trimmingCharacters(in: .whitespaces).hasPrefix("lands "))
        }
        var timings: [ResetTiming] = []
        for clause in candidates {
            // A mixed reset/eligibility sentence or alternative times is not a precise schedule.
            if ["upgrade", "qualify", "sign up", "subscribe", "purchase", " or ", "between "].contains(where: clause.contains) { return nil }
            let relative = Self.captures(#"\b(?:in|within|over)\s+((?:the\s+)?next\s+)?(?:(~|about|approximately)\s*)?(\d+|an?|one|two|three|half)?\s*(minutes?|hours?)\b"#, in: clause)
            let clock = Self.captures(#"\b(?:at|by|before)\s+(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(pdt|pst|pt|utc|gmt)\b"#, in: clause)
            guard relative.count + clock.count <= 1 else { return nil }
            if let captures = relative.first {
                let amount = captures[3].isEmpty ? (captures[1].isEmpty ? nil : 1.0) :
                    Double(captures[3]) ?? ["a": 1.0, "an": 1, "one": 1, "two": 2, "three": 3, "half": 0.5][captures[3]]
                if let amount, amount > 0, amount <= 1440 {
                    let seconds = amount * (captures[4].hasPrefix("hour") ? 3600 : 60)
                    guard seconds <= 7 * 86400 else { continue }
                    timings.append(ResetTiming(date: date.addingTimeInterval(seconds),
                        isDeadline: !captures[1].isEmpty || clause.contains("within ") || clause.contains("over "),
                        isApproximate: !captures[2].isEmpty))
                }
            } else if let captures = clock.first {
                guard let hourValue = Int(captures[1]), let minute = Int(captures[2].isEmpty ? "0" : captures[2]), minute < 60 else { continue }
                var hour = hourValue
                if !captures[3].isEmpty {
                    guard (1...12).contains(hour) else { continue }
                    hour = hour % 12 + (captures[3] == "pm" ? 12 : 0)
                } else if !(0...23).contains(hour) { continue }
                let zone: TimeZone?
                switch captures[4] {
                case "pt": zone = TimeZone(identifier: "America/Los_Angeles")
                case "pdt": zone = TimeZone(secondsFromGMT: -7 * 3600)
                case "pst": zone = TimeZone(secondsFromGMT: -8 * 3600)
                default: zone = TimeZone(secondsFromGMT: 0)
                }
                guard let zone else { continue }
                // Without an explicit relative day, a clock time alone is ambiguous.
                guard clause.contains("today") || clause.contains("tomorrow") else { continue }
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = zone
                guard let day = calendar.date(byAdding: .day, value: clause.contains("tomorrow") ? 1 : 0, to: date),
                      let target = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                      target >= date else { continue }
                timings.append(ResetTiming(date: target,
                    isDeadline: clause.contains("by ") || clause.contains("before "), isApproximate: false))
            }
        }
        // Multiple different times could refer to separate resets; do not invent a single one.
        guard let first = timings.first, timings.allSatisfy({ $0.date == first.date }) else { return nil }
        return first
    }

    private static func captures(_ pattern: String, in text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        return expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: text).map { String(text[$0]) } ?? ""
            }
        }
    }
}
