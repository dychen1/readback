import MCP
import ReadBackCore

/// The `play` and `stop` tools agents use to speak through ReadBack.
struct ReadBackMCPTools: Sendable {
    static let instructions = """
        ReadBack speaks text aloud on the user's Mac with local text-to-speech. \
        Call play with text written for listening. Play returns when playback starts. \
        Call stop to end the reading.
        """

    static let play = Tool(
        name: "play",
        title: "Read aloud",
        description: """
            Reads text aloud on the user's Mac through ReadBack. Pass the complete text \
            to speak. Write it for listening, as plain sentences without Markdown, code, \
            or raw URLs. The tool returns when playback starts. It does not wait for \
            playback to finish. A new reading stops the current reading, whatever app or \
            agent started it.
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
            Stops the current reading, whatever app or agent started it. If ReadBack is \
            not reading, the tool does nothing.
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

    /// - Parameter clientName: The name the calling host sent in `initialize`, if known.
    ///   History shows a known host by its display name, for example "Claude Code", only
    ///   when the name matches exactly.
    func call(_ parameters: CallTool.Parameters, clientName: String?) async throws -> CallTool.Result {
        switch parameters.name {
        case Self.play.name:
            guard let text = parameters.arguments?["text"]?.stringValue else {
                return Self.result(
                    "The \"text\" argument must be a string with the text to read aloud.",
                    isError: true
                )
            }
            let id: String
            do {
                id = try await reader.start(
                    ReadingRequest(text: text),
                    historySource: .agent(
                        reportedHost: clientName.map { MCPHost.historyLabel(clientName: $0) }
                    )
                )
            } catch {
                return Self.result(error.message, isError: true)
            }
            switch await coordinator.waitUntilAudioStarts(sessionID: id) {
            case nil, .completed:
                return Self.result(
                    "Started reading \(text.count) characters aloud. "
                        + "Playback continues in the background."
                )
            case .interrupted:
                return Self.result("A newer reading replaced this one before it started.", isError: true)
            case .stopped:
                return Self.result("A stop request ended the reading before it started.", isError: true)
            case .failed(let message):
                return Self.result("Speech failed: \(message)", isError: true)
            }
        case Self.stop.name:
            let stopped = await coordinator.stop()
            return Self.result(stopped ? "Stopped the current reading." : "Nothing was playing.")
        default:
            throw MCPError.invalidParams("ReadBack has no tool named \"\(parameters.name)\".")
        }
    }

    private static func result(_ text: String, isError: Bool = false) -> CallTool.Result {
        .init(content: [.text(text: text, annotations: nil, _meta: nil)], isError: isError)
    }
}
