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
        while RMD is switched on. Audio is never stored, only text. \
        "Me" is what the microphone heard: mostly the user, sometimes people sitting nearby and, on laptop speakers, \
        a copy of what "Others" just said. "Others" is what the Mac played during a call (calls in Zoom, Teams, Meet \
        and similar apps are recorded automatically): normally the other people on the call, all under this one label \
        because RMD cannot tell them apart, and now and then a video or another sound playing at the same time. \
        The user speaks English, Hindi and Hinglish; Hindi is written in Roman letters the way the speech model spells \
        it (nahin, achchha, thik hai, haan). Transcription is automatic, so expect misheard words. A line that repeats \
        the same few words many times, or only lists the names below, is a recognition glitch: leave it out. If a line \
        does not fit the conversation around it, do not attribute it to the call. \
        Times are local to the user's Mac (\(TimeZone.current.identifier)). Each paragraph starts with the time it began; \
        a gap means nobody spoke or RMD was off. For a whole day or a meeting, call list_sessions first and read one block \
        at a time with get_transcript (from, to). When summarizing, anchor every point to times from the transcript, and \
        name who said something only when the transcript itself shows it.\(vocabularyNote.map { " " + $0 } ?? "")
        """
    }

    /// The user's names and jargon, so Claude can read a similar-sounding word as the name it was.
    private static var vocabularyNote: String? {
        let words = Vocabulary.load()
        guard !words.isEmpty else { return nil }
        return "Names and words the user says often (a misheard one may appear as a similar-sounding word): \(words.joined(separator: ", "))."
    }

    private static let maxLines = 3000
    /// About 15–20k tokens: what an MCP client takes in one tool result. A busy day is four or five times that.
    private static let maxCharacters = 60_000
    private static let gapWorthMentioning: TimeInterval = 10 * 60
    private static let gapBetweenSessions: TimeInterval = 5 * 60

    static let definitions: [Tool] = [
        Tool(
            name: "list_days",
            title: "List recorded days",
            description: "Days that have a transcript, newest first, with the number of lines and the first and last time speech was heard.",
            inputSchema: schema(["limit": integer("How many days to return. Default 30.")]),
            annotations: readOnly
        ),
        Tool(
            name: "list_sessions",
            title: "List a day's sessions",
            description: "A short outline of one day: each stretch of speech (split where nobody spoke for 5 minutes) with its start and end, whether it was a call, and how much was said. Use it first for 'summarize my day', 'what calls did I have' or 'my 11am meeting', then read the block you need with get_transcript.",
            inputSchema: schema(["date": string("Day as YYYY-MM-DD, or 'today' / 'yesterday'. Default: today.")]),
            annotations: readOnly
        ),
        Tool(
            name: "get_transcript",
            title: "Get transcript",
            description: "The timestamped transcript for one day, optionally limited to a time window. A long result stops at about 60,000 characters and says how to get the rest.",
            inputSchema: schema([
                "date": string("Day as YYYY-MM-DD, or 'today' / 'yesterday'. Default: today."),
                "from": string("Optional start time on that day, 24-hour HH:mm or HH:mm:ss (e.g. 14:00)."),
                "to": string("Optional end time, 24-hour HH:mm or HH:mm:ss (e.g. 17:30). A time earlier than 'from' means the next day, for a call that ran past midnight."),
            ]),
            annotations: readOnly
        ),
        Tool(
            name: "search_transcript",
            title: "Search transcript",
            description: "Find lines containing words or a phrase, newest first, with their date and time. Use it for 'when did we talk about pricing?'.",
            inputSchema: schema([
                "query": string("Words to look for. Hindi is stored in Roman letters the way the speech model spells it (nahin, achchha, thik hai, haan), so try that spelling, or fewer words."),
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
            let limit = min(max(1, try number(arguments["limit"], "limit") ?? 30), 3660)
            let days = try await store.days(limit: limit)
            guard !days.isEmpty else { return "No transcript yet." }
            return days.map { day in
                "\(date(day.date)) (\(day.date.formatted(.dateTime.weekday(.wide)))): "
                    + "\(day.lineCount) lines, \(clock(day.first))–\(clock(day.last))"
            }.joined(separator: "\n")

        case "list_sessions":
            let day = try parseDay(try text(arguments["date"], "date"))
            let sessions = try await store.sessions(from: day, to: day.addingDays(1), gap: gapBetweenSessions)
            // A session that began the day before and ran past midnight is listed under that day: say so here.
            let carried = try await store.sessions(from: day.addingDays(-1), to: day, gap: gapBetweenSessions).last
                .flatMap { $0.last > day ? $0 : nil }
            let heading = "Sessions on \(day.formatted(date: .complete, time: .omitted)) (times in \(TimeZone.current.identifier))"
            guard !sessions.isEmpty || carried != nil else { return heading + "\nNo speech was recorded on this day." }
            var carriedRow: [String] = []
            if let carried {
                let began = clock(carried.first, seconds: false)
                let end = clock(carried.last.addingTimeInterval(59), seconds: false)
                let read = "date: \"\(date(carried.first))\", from: \"\(began)\", to: \"\(end)\""
                carriedRow = ["00:00–\(end)  end of a session that began at \(began) the day before (read it with \(read))"]
            }
            let rows = sessions.map { session in
                let call = session.others > 0 ? "call\(session.app.map { " in \($0)" } ?? "") · " : ""
                // The end is rounded up to the minute, so reading "from–to" as listed includes the last line.
                let end = session.last.addingTimeInterval(59)
                let nextDay = Calendar.current.isDate(end, inSameDayAs: day) ? "" : " (next day)"
                let count = session.mine + session.others
                let lines = "\(count) line\(count == 1 ? "" : "s") (Me \(session.mine), Others \(session.others))"
                return "\(clock(session.first, seconds: false))–\(clock(end, seconds: false))\(nextDay)  \(call)\(lines) · about \(session.words) words"
            }
            let footer = "Read one with get_transcript (date: \"\(date(day))\", from and to as listed)."
            let output: [String] = [heading + ", split where nobody spoke for 5 minutes:"] + carriedRow + rows + [footer]
            return output.joined(separator: "\n")

        case "get_transcript":
            let day = try parseDay(try text(arguments["date"], "date"))
            let start = try text(arguments["from"], "from").map { try time($0, on: day) } ?? day
            let until = try text(arguments["to"], "to")
            var end = try until.map { try time($0, on: day) } ?? day.addingDays(1)
            // "23:30 to 00:30" is a call that ran past midnight.
            let wraps = until != nil && end <= start
            if wraps { end = end.addingDays(1) }
            let lines = try await store.lines(from: start, to: end, limit: maxLines + 1)
            let window = start == day && end == day.addingDays(1)
                ? "" : ", \(clock(start, seconds: false))–\(clock(end, seconds: false))\(wraps ? " (next day)" : "")"
            return render(
                lines,
                heading: "Transcript for \(day.formatted(date: .complete, time: .omitted))\(window)",
                day: day,
                until: until
            )

        case "search_transcript":
            guard let query = arguments["query"]?.stringValue, !query.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw ToolError("Give a 'query' to search for.")
            }
            let daysBack = max(1, try number(arguments["days_back"], "days_back") ?? 30)
            let limit = min(max(1, try number(arguments["limit"], "limit") ?? 50), 200)
            let since = Calendar.current.startOfDay(for: .now).addingDays(1 - daysBack)
            let (lines, match) = try await store.search(query, since: since, limit: limit)
            guard !lines.isEmpty else {
                return "No lines matching \"\(query)\" in the last \(daysBack) days. Hindi is spelled the speech model's way "
                    + "(nahin, achchha, thik hai, haan): try that spelling, the first letters of a word, or fewer words."
            }
            let found = "\(lines.count) line\(lines.count == 1 ? "" : "s")"
            let heading = switch match {
            case .allWords, .phrase: "\(found) matching \"\(query)\", newest first:"
            case .wordStarts: "\(found) with words starting like \"\(query)\", newest first:"
            case .someWords: "No line has all of \"\(query)\" (Hindi is spelled the speech model's way: nahin, achchha, thik hai, haan). "
                + "\(found) with some of the words, best matches first:"
            }
            let more = lines.count == limit ? ["(Showing \(limit); there may be more. Raise 'limit' or lower 'days_back'.)"] : []
            return ([heading] + lines.map { "\(date($0.start)) \(row($0))" } + more
                + ["To read around a hit, call get_transcript with its date and a from–to window around its time."])
                .joined(separator: "\n")

        case "get_recent":
            let minutes = min(max(1, try number(arguments["minutes"], "minutes") ?? 30), 24 * 60)
            let now = Date.now
            let from = now.addingTimeInterval(-Double(minutes) * 60)
            let lines = try await store.lines(from: from, to: now, limit: maxLines + 1)
            // The resume hint names one day; a 'to' earlier than 'from' means the next day, so one call
            // still reaches past midnight.
            return render(lines, heading: "Transcript for the last \(minutes) minutes",
                          day: Calendar.current.startOfDay(for: from), until: clock(now))

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

    /// `day` is the day the heading names; lines on another day get a date line first. `until` is the
    /// caller's 'to', repeated in the hint for getting the rest of a long result.
    private static func render(_ lines: [TranscriptLine], heading: String, day: Date, until: String?) -> String {
        var output = ["\(heading) (times in \(TimeZone.current.identifier))"]
        guard !lines.isEmpty else { return output[0] + "\nNo speech was recorded in this period." }
        if let vocabularyNote { output.append(vocabularyNote) }

        // The hint's 'from' has whole seconds: never cut inside a second a shown line began in,
        // or the next page would show that line again.
        var shown = min(lines.count, maxLines)
        while lines.count > maxLines, shown > 1, sameSecond(lines[shown - 1].start, lines[shown].start) { shown -= 1 }

        var size = 0
        var previous: TranscriptLine?
        var shownDay = day
        var app: String?
        var next: Date?  // where a cut-off result carries on
        var lastStart: Date?  // when the last line shown began
        for (line, last) in paragraphs(Array(lines.prefix(shown))) {
            if size >= maxCharacters, lastStart.map({ !sameSecond($0, line.start) }) ?? true {
                next = line.start
                break
            }
            if !Calendar.current.isDate(line.start, inSameDayAs: shownDay) {
                shownDay = Calendar.current.startOfDay(for: line.start)
                output.append("— \(shownDay.formatted(date: .complete, time: .omitted)) —")
            }
            if let previous, line.start.timeIntervalSince(previous.end) >= gapWorthMentioning {
                output.append("   · · · \(Int(line.start.timeIntervalSince(previous.end) / 60)) min with no speech · · ·")
            }
            if let lineApp = line.app, lineApp != app {
                output.append("   · · · call in \(lineApp) · · ·")
            }
            app = line.app
            let text = row(line)
            output.append(text)
            size += text.count + 1
            previous = line
            lastStart = last
        }
        if next == nil, lines.count > maxLines { next = lines[shown].start }
        if let next {
            let to = until.map { ", to: \"\($0)\"" } ?? ""
            output.append("(Stopped before \(clock(next)); more follows. Call get_transcript again with "
                + "date: \"\(date(next))\", from: \"\(clock(next))\"\(to) for the rest.)")
        }
        return output.joined(separator: "\n")
    }

    /// Lines are cut at every pause, so one sentence is often two or three of them. Lines from the same
    /// side that follow each other within 3 s read as one paragraph, up to a minute long. A longer pause
    /// stays a break: on the "Others" side it is the only hint that someone else started talking.
    /// Each paragraph comes with the start of the last line in it, where a page may not be cut.
    private static func paragraphs(_ lines: [TranscriptLine]) -> [(line: TranscriptLine, lastStart: Date)] {
        var merged: [(line: TranscriptLine, lastStart: Date)] = []
        for line in lines {
            if let last = merged.last?.line, last.source == line.source, last.app == line.app,
               line.start.timeIntervalSince(last.end) < 3, line.start.timeIntervalSince(last.start) < 60 {
                merged[merged.count - 1] = (TranscriptLine(
                    start: last.start, end: max(last.end, line.end), source: last.source,
                    text: last.text + " " + line.text, language: last.language, app: last.app
                ), line.start)
            } else {
                merged.append((line, line.start))
            }
        }
        return merged
    }

    /// Whether both times print as the same HH:mm:ss, the resolution of a resume hint's 'from'.
    private static func sameSecond(_ a: Date, _ b: Date) -> Bool {
        a.timeIntervalSince1970.rounded(.down) == b.timeIntervalSince1970.rounded(.down)
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

    /// YYYY-MM-DD, the form the `date` arguments take.
    private static func date(_ date: Date) -> String {
        local(date, "\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits)")
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
            let pieces = text.split(separator: "-", omittingEmptySubsequences: false)
            let parts = pieces.compactMap { Int($0) }
            // Calendar rolls 2026-13-45 over into another month; only a date that reads back the same is real.
            guard parts.count == 3, pieces.count == 3,
                  let date = Calendar.current.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
                  case let read = Calendar.current.dateComponents([.year, .month, .day], from: date),
                  read.year == parts[0], read.month == parts[1], read.day == parts[2]
            else { throw ToolError("Couldn't read date \"\(text)\". Use YYYY-MM-DD, 'today' or 'yesterday'.") }
            return date
        }
    }

    private static func time(_ text: String, on day: Date) throws -> Date {
        let pieces = text.split(separator: ":", omittingEmptySubsequences: false)
        let parts = pieces.compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == pieces.count, (1...3).contains(parts.count), (0...24).contains(parts[0]) else {
            throw ToolError("Couldn't read time \"\(text)\". Use 24-hour HH:mm, e.g. 14:30.")
        }
        let minute = parts.count >= 2 ? parts[1] : 0
        let second = parts.count == 3 ? parts[2] : 0
        // 24:00 is the end of the day; 24:30 is not a time.
        guard (0..<60).contains(minute), (0..<60).contains(second), parts[0] < 24 || (minute == 0 && second == 0) else {
            throw ToolError("Couldn't read time \"\(text)\".")
        }
        return day.addingTimeInterval(Double(parts[0] * 3600 + minute * 60 + second))
    }

    /// Text, or nil when the argument is absent: a date or time sent as a number is refused, not ignored.
    private static func text(_ value: Value?, _ name: String) throws -> String? {
        guard let value, !value.isNull else { return nil }
        guard let text = value.stringValue else {
            throw ToolError("'\(name)' must be text, e.g. \"\(name == "date" ? "2026-11-02" : "14:30")\".")
        }
        return text
    }

    /// A whole number, also when the client sends it as 30.0 or "30". Nil when the argument is absent.
    private static func number(_ value: Value?, _ name: String) throws -> Int? {
        guard let value, !value.isNull else { return nil }
        guard let number = Int(value, strict: false) else { throw ToolError("'\(name)' must be a whole number.") }
        return number
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
