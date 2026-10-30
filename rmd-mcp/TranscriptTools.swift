import Foundation
import MCP

enum TranscriptTools {
    struct ToolError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    static var instructions: String {
        """
        RMD (Record My Day) keeps a timestamped text transcript of the user's day, captured on their Mac \
        while RMD is switched on. Audio is never stored, only text. Each line has a time, a speaker source \
        and the words: "Me" is the user's microphone; "Others" is audio playing on the computer (calls, videos). \
        The user speaks English, Hindi and Hinglish; Hindi is written in Roman letters (e.g. "kya tum hindi bol sakte ho"). \
        Transcription is automatic, so expect some misheard words. Times are local to the user's Mac (\(TimeZone.current.identifier)). \
        Gaps between lines mean nobody spoke or RMD was off. When summarizing, anchor every point to times from the transcript.
        """
    }

    private static let maxLines = 3000
    private static let gapWorthMentioning: TimeInterval = 10 * 60

    static let definitions: [Tool] = [
        Tool(
            name: "list_days",
            title: "List recorded days",
            description: "Days that have a transcript, newest first, with the number of lines and the first and last time speech was heard.",
            inputSchema: schema(["limit": integer("How many days to return. Default 30.")]),
            annotations: readOnly
        ),
        Tool(
            name: "get_transcript",
            title: "Get transcript",
            description: "The timestamped transcript for one day, optionally limited to a time window. Use this for 'what happened today', 'between 2 and 5pm' or 'my 11am meeting'.",
            inputSchema: schema([
                "date": string("Day as YYYY-MM-DD, or 'today' / 'yesterday'. Default: today."),
                "from": string("Optional start time on that day, 24-hour HH:mm (e.g. 14:00)."),
                "to": string("Optional end time on that day, 24-hour HH:mm (e.g. 17:30)."),
            ]),
            annotations: readOnly
        ),
        Tool(
            name: "search_transcript",
            title: "Search transcript",
            description: "Find lines containing words or a phrase, newest first, with their date and time. Use it for 'when did we talk about pricing?'.",
            inputSchema: schema([
                "query": string("Words to look for. Hindi is stored in Roman letters, so search 'kal meeting' rather than Devanagari."),
                "days_back": integer("How many days back to search. Default 30."),
                "limit": integer("Maximum lines to return. Default 50, maximum 200."),
            ], required: ["query"]),
            annotations: readOnly
        ),
        Tool(
            name: "get_recent",
            title: "Get recent transcript",
            description: "Everything heard in the last N minutes.",
            inputSchema: schema(["minutes": integer("How many minutes back. Default 30.")]),
            annotations: readOnly
        ),
    ]

    static func call(_ params: CallTool.Parameters) async -> CallTool.Result {
        do {
            let text = try await run(params.name, arguments: params.arguments ?? [:])
            return .init(content: [.text(text)], isError: false)
        } catch {
            return .init(content: [.text("\(error)")], isError: true)
        }
    }

    private static func run(_ name: String, arguments: [String: Value]) async throws -> String {
        let store = try openStore()
        switch name {
        case "list_days":
            let days = try await store.days(limit: arguments["limit"]?.intValue ?? 30)
            guard !days.isEmpty else { return "No transcript yet." }
            return days.map { day in
                "\(local(day.date, "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)")) (\(day.date.formatted(.dateTime.weekday(.wide)))): "
                    + "\(day.lineCount) lines, \(clock(day.first))–\(clock(day.last))"
            }.joined(separator: "\n")

        case "get_transcript":
            let day = try parseDay(arguments["date"]?.stringValue)
            let start = try arguments["from"]?.stringValue.map { try time($0, on: day) } ?? day
            let end = try arguments["to"]?.stringValue.map { try time($0, on: day) } ?? day.addingDays(1)
            guard start < end else { throw ToolError("'from' must be before 'to'.") }
            let lines = try await store.lines(from: start, to: end, limit: maxLines + 1)
            let window = start == day && end == day.addingDays(1) ? "" : ", \(clock(start, seconds: false))–\(clock(end, seconds: false))"
            return render(lines, heading: "Transcript for \(day.formatted(date: .complete, time: .omitted))\(window)")

        case "search_transcript":
            guard let query = arguments["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ToolError("Give a 'query' to search for.")
            }
            let daysBack = max(1, arguments["days_back"]?.intValue ?? 30)
            let limit = min(max(1, arguments["limit"]?.intValue ?? 50), 200)
            let since = Calendar.current.startOfDay(for: .now).addingDays(1 - daysBack)
            let lines = try await store.search(query, since: since, limit: limit)
            guard !lines.isEmpty else { return "No lines matching \"\(query)\" in the last \(daysBack) days." }
            return "\(lines.count) lines matching \"\(query)\", newest first:\n"
                + lines.map { "\($0.start.formatted(.dateTime.weekday().day().month())) \(row($0))" }.joined(separator: "\n")

        case "get_recent":
            let minutes = min(max(1, arguments["minutes"]?.intValue ?? 30), 24 * 60)
            let lines = try await store.lines(from: .now.addingTimeInterval(-Double(minutes) * 60), to: .now, limit: maxLines + 1)
            return render(lines, heading: "Transcript for the last \(minutes) minutes")

        default:
            throw ToolError("Unknown tool \(name).")
        }
    }

    private static func openStore() throws -> TranscriptStore {
        let url = try TranscriptStore.defaultURL()
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ToolError("No transcript yet: switch RMD on from the menu bar to start recording the day.")
        }
        return try TranscriptStore(url: url, readOnly: true)
    }

    private static func render(_ lines: [TranscriptLine], heading: String) -> String {
        var output = ["\(heading) (times in \(TimeZone.current.identifier))"]
        guard !lines.isEmpty else { return output[0] + "\nNo speech was recorded in this period." }

        var previousEnd: Date?
        for line in lines.prefix(maxLines) {
            if let previousEnd, line.start.timeIntervalSince(previousEnd) >= gapWorthMentioning {
                output.append("   · · · \(Int(line.start.timeIntervalSince(previousEnd) / 60)) min with no speech · · ·")
            }
            output.append(row(line))
            previousEnd = line.end
        }
        if lines.count > maxLines {
            output.append("(Stopped at \(maxLines) lines. Ask for a shorter time window to see the rest.)")
        }
        return output.joined(separator: "\n")
    }

    private static func row(_ line: TranscriptLine) -> String {
        "\(clock(line.start))  \(line.source == .me ? "Me" : "Others"): \(line.text)"
    }

    /// 24-hour local time, e.g. 22:50:30.
    private static func clock(_ date: Date, seconds: Bool = true) -> String {
        let hour = Date.FormatStyle.Symbol.VerbatimHour.twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased)
        return seconds
            ? local(date, "\(hour: hour):\(minute: .twoDigits):\(second: .twoDigits)")
            : local(date, "\(hour: hour):\(minute: .twoDigits)")
    }

    private static func local(_ date: Date, _ format: Date.FormatString) -> String {
        date.formatted(Date.VerbatimFormatStyle(format: format, timeZone: .current, calendar: .current))
    }

    private static func parseDay(_ value: String?) throws -> Date {
        let today = Calendar.current.startOfDay(for: .now)
        switch value?.lowercased().trimmingCharacters(in: .whitespaces) {
        case nil, "", "today": return today
        case "yesterday": return today.addingDays(-1)
        case let text?:
            let parts = text.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3,
                  let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
            else { throw ToolError("Couldn't read date \"\(text)\". Use YYYY-MM-DD, 'today' or 'yesterday'.") }
            return date
        }
    }

    private static func time(_ text: String, on day: Date) throws -> Date {
        let parts = text.split(separator: ":").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard (1...2).contains(parts.count), (0...24).contains(parts[0]) else {
            throw ToolError("Couldn't read time \"\(text)\". Use 24-hour HH:mm, e.g. 14:30.")
        }
        let minute = parts.count == 2 ? parts[1] : 0
        guard (0..<60).contains(minute) else { throw ToolError("Couldn't read time \"\(text)\".") }
        return day.addingTimeInterval(Double(parts[0] * 3600 + minute * 60))
    }

    private static let readOnly = Tool.Annotations(readOnlyHint: true, openWorldHint: false)

    private static func schema(_ properties: [String: Value], required: [String] = []) -> Value {
        .object([
            "type": .string("object"),
            "properties": .object(properties),
            "required": .array(required.map { .string($0) }),
        ])
    }

    private static func string(_ description: String) -> Value {
        .object(["type": .string("string"), "description": .string(description)])
    }

    private static func integer(_ description: String) -> Value {
        .object(["type": .string("integer"), "description": .string(description)])
    }
}

private extension Date {
    func addingDays(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: self) ?? self
    }
}
