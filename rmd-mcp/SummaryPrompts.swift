import MCP

/// Ready-made requests that show up as slash commands / prompts in MCP clients.
/// They ask the client's model to read the transcript with the tools and summarize it.
enum SummaryPrompts {
    private static let date = Prompt.Argument(
        name: "date", description: "YYYY-MM-DD, 'today' or 'yesterday'. Default: today.", required: false
    )

    static let definitions: [Prompt] = [
        Prompt(
            name: "summarize_day",
            title: "Summarize my day",
            description: "A timeline of the day in time blocks, with decisions and action items.",
            arguments: [date]
        ),
        Prompt(
            name: "summarize_time_range",
            title: "Summarize a time range",
            description: "What happened between two times on a day.",
            arguments: [
                date,
                .init(name: "from", description: "Start time, 24-hour HH:mm", required: true),
                .init(name: "to", description: "End time, 24-hour HH:mm", required: true),
            ]
        ),
        Prompt(
            name: "summarize_meeting",
            title: "Summarize a meeting",
            description: "Find a meeting or call around a time and summarize it.",
            arguments: [
                date,
                .init(name: "around", description: "Roughly when it happened, 24-hour HH:mm", required: true),
            ]
        ),
    ]

    static func get(_ params: GetPrompt.Parameters) throws -> GetPrompt.Result {
        let arguments = params.arguments ?? [:]
        let day = arguments["date"].flatMap { $0.isEmpty ? nil : $0 } ?? "today"
        let request: String

        switch params.name {
        case "summarize_day":
            request = """
                Read my RMD transcript for \(day) with get_transcript (date: \(day)) and summarize my day:
                1. Timeline: time blocks like "09:00–09:40 · …", merging lines that belong together and marking meetings and calls.
                2. Decisions that were made.
                3. Action items and commitments: what, who, and the time it was said.
                4. Anything I said I would follow up on.
                """
        case "summarize_time_range":
            let from = arguments["from"] ?? "", to = arguments["to"] ?? ""
            request = """
                Read my RMD transcript for \(day) from \(from) to \(to) with get_transcript and summarize that period:
                a short timeline in time blocks, decisions, and action items with the time each was said.
                """
        case "summarize_meeting":
            let around = arguments["around"] ?? ""
            request = """
                Find the meeting or call in my RMD transcript on \(day) around \(around): read get_transcript for about an hour \
                either side of \(around), then pick out the stretch of back-and-forth conversation (calls usually include "Others" lines).
                Report its start and end time, topic, people mentioned, main discussion points, decisions, \
                and action items with owner and the time each was said.
                """
        default:
            throw MCPError.invalidParams("Unknown prompt \(params.name)")
        }

        let rules = """

            Use only times that appear in the transcript. "Me" is me; "Others" is audio from my computer. \
            Write the summary in English; quote short Hinglish phrases as spoken when they matter.
            """
        return .init(description: params.name, messages: [.user(.text(text: request + rules))])
    }
}
