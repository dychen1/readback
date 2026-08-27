import ReadBackCore

func streamChunkerTests() -> [TestCase] {
    [
        TestCase(name: "chunker emits a complete sentence and retains the remainder") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("First sentence. Second")

            try expectEqual(
                chunks,
                [StreamedTextChunk(text: "First sentence.", endsParagraph: false)],
                "sentence chunks"
            )
            try expectEqual(
                chunker.flush(),
                StreamedTextChunk(text: "Second", endsParagraph: false),
                "retained remainder"
            )
        },
        TestCase(name: "chunker coalesces complete sentences appended together") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("First sentence. Second sentence.")

            try expectEqual(
                chunks,
                [
                    StreamedTextChunk(
                        text: "First sentence. Second sentence.",
                        endsParagraph: false
                    )
                ],
                "coalesced sentence chunk"
            )
        },
        TestCase(name: "chunker emits at a paragraph boundary") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("First paragraph\n\nNext paragraph")

            try expectEqual(
                chunks,
                [StreamedTextChunk(text: "First paragraph", endsParagraph: true)],
                "paragraph chunks"
            )
            try expectEqual(
                chunker.flush(),
                StreamedTextChunk(text: "Next paragraph", endsParagraph: false),
                "paragraph remainder"
            )
        },
        TestCase(name: "chunker preserves a paragraph break after sentence punctuation") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("First paragraph.\n\nNext paragraph")

            try expectEqual(
                chunks,
                [StreamedTextChunk(text: "First paragraph.", endsParagraph: true)],
                "punctuated paragraph chunk"
            )
        },
        TestCase(name: "chunker flushes incomplete text after idle input") {
            var chunker = StreamingTextChunker(maxCharacters: 250)
            _ = chunker.append("No punctuation yet")

            try expectEqual(
                chunker.flush(),
                StreamedTextChunk(text: "No punctuation yet", endsParagraph: false),
                "idle flush"
            )
            try expectEqual(chunker.flush(), nil, "second flush must be empty")
        },
        TestCase(name: "chunker hard split is Unicode safe") {
            var chunker = StreamingTextChunker(maxCharacters: 250)
            let input = String(repeating: "🙂", count: 251)

            let chunks = chunker.append(input)

            try expectEqual(chunks.count, 1, "hard split count")
            try expectEqual(chunks.first?.text.count, 250, "hard split character count")
            try expectEqual(chunks.first?.endsParagraph, false, "hard split paragraph marker")
            try expectEqual(
                chunker.flush(),
                StreamedTextChunk(text: "🙂", endsParagraph: false),
                "Unicode remainder"
            )
        },
    ]
}
