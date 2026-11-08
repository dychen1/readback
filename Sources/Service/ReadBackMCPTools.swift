import MCP
import ReadBackCore

/// The `play` and `stop` tools agents use to speak through ReadBack.
struct ReadBackMCPTools: Sendable {
    static let instructions = """
        ReadBack speaks text aloud on the user's Mac with local text-to-speech. \
        Call play with text written for listening; it returns as soon as playback starts. \
        Call stop to silence it.
        """

    static let play = Tool(
        name: "play",
        title: "Read aloud",
        description: """
            Read text aloud on the user's Mac through ReadBack. Pass the complete text \
            to speak, written for listening: plain sentences without Markdown, code, or \
            raw URLs. Returns as soon as playback starts and does not wait for it to \
            finish. A new reading stops whatever ReadBack was already reading, whichever \
            app or agent started it.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([
                "text": .object([
                    "type": "string",
                    "minLength": 1,
                    "description": """
                        The complete text to speak, as plain prose. A blank line between \
                        paragraphs becomes a short pause.
                        """,
                ]),
            ]),
            "required": .array(["text"]),
            "additionalProperties": false,
        ]),
        annotations: .init(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: false,
            openWorldHint: false
        )
    )

    static let stop = Tool(
        name: "stop",
        title: "Stop reading",
        description: """
            Stop whatever ReadBack is reading aloud, whichever app or agent started it. \
            Does nothing when ReadBack is silent.
            """,
        inputSchema: .object([
            "type": "object",
            "properties": .object([:]),
            "additionalProperties": false,
        ]),
        annotations: .init(
            readOnlyHint: false,
            destructiveHint: false,
            idempotentHint: true,
            openWorldHint: false
        )
    )

    static let definitions = [play, stop]

    let reader: ReadingStarter
    let coordinator: SpeechCoordinator

    func call(_ parameters: CallTool.Parameters) async throws -> CallTool.Result {
        switch parameters.name {
        case Self.play.name:
            guard let text = parameters.arguments?["text"]?.stringValue else {
                return Self.result(
                    "The \"text\" argument must be a string with the text to read aloud.",
                    isError: true
                )
            }
            do {
                _ = try await reader.start(ReadingRequest(text: text))
            } catch {
                return Self.result(error.message, isError: true)
            }
            return Self.result(
                "Started reading \(text.count) characters aloud. "
                    + "Playback continues in the background."
            )
        case Self.stop.name:
            let stopped = await coordinator.stop()
            return Self.result(stopped ? "Stopped the current reading." : "Nothing was playing.")
        default:
            throw MCPError.invalidParams("Unknown tool: \(parameters.name)")
        }
    }

    private static func result(_ text: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }
}
