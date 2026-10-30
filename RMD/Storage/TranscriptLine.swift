import Foundation

struct TranscriptLine: Identifiable, Sendable, Equatable {
    enum Source: String, Sendable {
        case me
        case others
    }

    var id: Int64 = 0
    let start: Date
    let end: Date
    let source: Source
    let text: String
    let language: String?
}
