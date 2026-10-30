import Foundation
import MCP

// RMD's MCP server. An MCP client (Claude Code, Claude Desktop, …) launches this over stdio
// to read the transcript of your day. It only ever reads; recording happens in the app.

let server = Server(
    name: "rmd",
    version: "0.1.0",
    title: "RMD — Record My Day",
    instructions: TranscriptTools.instructions,
    capabilities: .init(prompts: .init(listChanged: false), tools: .init(listChanged: false))
)

await server.withMethodHandler(ListTools.self) { _ in
    .init(tools: TranscriptTools.definitions)
}
await server.withMethodHandler(CallTool.self) { params in
    await TranscriptTools.call(params)
}
await server.withMethodHandler(ListPrompts.self) { _ in
    .init(prompts: SummaryPrompts.definitions)
}
await server.withMethodHandler(GetPrompt.self) { params in
    try SummaryPrompts.get(params)
}

try await server.start(transport: StdioTransport())
await server.waitUntilCompleted()
