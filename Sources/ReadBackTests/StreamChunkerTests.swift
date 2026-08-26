import ReadBackCore

func streamChunkerTests() -> [TestCase] {
    [
        TestCase(name: "chunker emits a complete sentence and retains the remainder") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("First sentence. Second")

            try expectEqual(chunks, ["First sentence."], "sentence chunks")
            try expectEqual(chunker.flush(), "Second", "retained remainder")
        },
        TestCase(name: "chunker emits at a paragraph boundary") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("First paragraph\n\nNext paragraph")

            try expectEqual(chunks, ["First paragraph"], "paragraph chunks")
            try expectEqual(chunker.flush(), "Next paragraph", "paragraph remainder")
        },
        TestCase(name: "chunker flushes incomplete text after idle input") {
            var chunker = StreamingTextChunker(maxCharacters: 250)
            _ = chunker.append("No punctuation yet")

            try expectEqual(chunker.flush(), "No punctuation yet", "idle flush")
            try expectEqual(chunker.flush(), nil, "second flush must be empty")
        },
        TestCase(name: "chunker hard split is Unicode safe") {
            var chunker = StreamingTextChunker(maxCharacters: 250)
            let input = String(repeating: "🙂", count: 251)

            let chunks = chunker.append(input)

            try expectEqual(chunks.count, 1, "hard split count")
            try expectEqual(chunks.first?.count, 250, "hard split character count")
            try expectEqual(chunker.flush(), "🙂", "Unicode remainder")
        },
    ]
}
