import Foundation

extension MermaidParser {

    static func parseGantt(body: [String]) -> GanttChart? {
        var title: String?
        var currentSection = ""
        var sections: [String] = []
        var tasks: [GanttChart.Task] = []
        var endByID: [String: Double] = [:]   // absolute end ordinal per task id
        var previousEnd: Double?               // absolute end of the previous task

        for (index, line) in body.enumerated() {
            // Directives (title / dateFormat / axisFormat / excludes / …).
            if line.hasPrefix("title ") {
                title = String(line.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("section ") {
                currentSection = String(line.dropFirst("section ".count)).trimmingCharacters(in: .whitespaces)
                if !sections.contains(currentSection) { sections.append(currentSection) }
                continue
            }
            guard let colon = line.firstIndex(of: ":") else { continue } // non-task directive
            let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let spec = String(line[line.index(after: colon)...])
            guard !label.isEmpty else { continue }

            // Comma-separated tokens: status tags, an optional id, a start
            // (date or `after …`), and a duration or end date — in any order.
            var status = GanttChart.Status.normal
            var isMilestone = false
            var id: String?
            var afterIDs: [String] = []
            var dates: [Double] = []
            var duration: Double?
            for token in spec.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !token.isEmpty {
                switch token.lowercased() {
                case "done": status = .done
                case "active": status = .active
                case "crit": status = .critical
                case "milestone": isMilestone = true
                default:
                    if token.lowercased().hasPrefix("after ") {
                        afterIDs = token.dropFirst("after ".count)
                            .split(separator: " ").map { String($0) }
                    } else if let ordinal = dayOrdinal(fromISODate: token) {
                        dates.append(ordinal)
                    } else if let days = durationInDays(token) {
                        duration = days
                    } else {
                        id = token   // a bare identifier
                    }
                }
            }

            // Resolve the absolute start ordinal.
            let start: Double
            if let first = dates.first {
                start = first
            } else if !afterIDs.isEmpty {
                start = afterIDs.compactMap { endByID[$0] }.max() ?? previousEnd ?? 0
            } else {
                start = previousEnd ?? 0
            }

            // Resolve the length in days.
            let length: Double
            if isMilestone {
                length = 0
            } else if dates.count >= 2 {
                length = max(0, dates[1] - start)  // start-date, end-date form
            } else {
                length = duration ?? 1
            }

            let taskID = id ?? "task\(index)"
            endByID[taskID] = start + length
            previousEnd = start + length
            tasks.append(GanttChart.Task(
                id: taskID, label: label, section: currentSection,
                start: start, length: length, isMilestone: isMilestone, status: status
            ))
        }

        guard !tasks.isEmpty else { return nil }

        // Normalize so the earliest task sits at day 0.
        let origin = tasks.map(\.start).min() ?? 0
        let normalized = tasks.map { task -> GanttChart.Task in
            var copy = task
            copy.start -= origin
            return copy
        }
        return GanttChart(title: title, tasks: normalized, sections: sections)
    }

    /// Julian Day Number for a proleptic-Gregorian `YYYY-MM-DD` string, or nil.
    /// Only day *differences* matter, so the absolute epoch is arbitrary; this
    /// is integer and timezone-free (works identically on Linux).
    static func dayOrdinal(fromISODate text: String) -> Double? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day), parts[0].count == 4
        else { return nil }
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        return Double(jdn)
    }

    /// A Mermaid duration like `30d`, `2w`, `12h` in days, or nil. A bare
    /// number is treated as days.
    static func durationInDays(_ text: String) -> Double? {
        guard let unit = text.last else { return nil }
        if let bare = Double(text) { return bare }  // "30" → 30 days
        let value = MermaidParser.finiteDouble(text.dropLast())
        guard let value, value >= 0 else { return nil }
        switch unit {
        case "d": return value
        case "w": return value * 7
        case "h": return value / 24
        case "m": return value / (24 * 60)   // minutes
        default: return nil
        }
    }
}
