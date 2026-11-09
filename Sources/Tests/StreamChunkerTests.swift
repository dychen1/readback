import Foundation
import ReadBackCore

func streamChunkerTests() -> [TestCase] {
    [
        TestCase(name: "chunker emits a complete sentence and retains the remainder") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("First sentence. Second")

            try expectEqual(
                chunks,
                [StreamedTextChunk(text: "First sentence.", endsParagraph: false, sourceRange: 0..<15)],
                "sentence chunks"
            )
            try expectEqual(
                chunker.flush(),
                StreamedTextChunk(text: "Second", endsParagraph: false, sourceRange: 16..<22),
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
                        endsParagraph: false,
                        sourceRange: 0..<32
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
                [StreamedTextChunk(text: "First paragraph", endsParagraph: true, sourceRange: 0..<15)],
                "paragraph chunks"
            )
            try expectEqual(
                chunker.flush(),
                StreamedTextChunk(text: "Next paragraph", endsParagraph: false, sourceRange: 17..<31),
                "paragraph remainder"
            )
        },
        TestCase(name: "chunker preserves a paragraph break after sentence punctuation") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("First paragraph.\n\nNext paragraph")

            try expectEqual(
                chunks,
                [StreamedTextChunk(text: "First paragraph.", endsParagraph: true, sourceRange: 0..<16)],
                "punctuated paragraph chunk"
            )
        },
        TestCase(name: "chunker splits a long paragraph that has no sentence end") {
            var chunker = StreamingTextChunker(maxCharacters: 250)
            // Words of 7 characters plus a space do not divide 250, so a cut at exactly
            // 250 characters would land inside a word.
            let paragraph = String(repeating: "wordies ", count: 400).trimmingCharacters(in: .whitespaces)

            let chunks = chunker.append(paragraph + "\n\nNext paragraph")

            try expect(chunks.count > 1, "long paragraph is split, got \(chunks.count) chunk(s)")
            try expect(chunks.allSatisfy { $0.text.count <= 250 }, "chunks stay within the limit")
            try expectEqual(chunks.last?.endsParagraph, true, "last chunk keeps the paragraph break")
            try expect(chunks.dropLast().allSatisfy { !$0.endsParagraph }, "only the last chunk ends the paragraph")
            try expect(
                chunks.allSatisfy { $0.text.split(separator: " ").allSatisfy { $0 == "wordies" } },
                "no word is cut"
            )
            try expectEqual(chunks.map(\.text).joined(separator: " "), paragraph, "every word is kept in order")
        },
        TestCase(name: "chunker splits a long CJK paragraph") {
            var chunker = StreamingTextChunker(maxCharacters: 250)
            let paragraph = String(repeating: "これは長い段落です。", count: 300)

            let chunks = chunker.append(paragraph + "\n\n次の段落")

            try expect(chunks.allSatisfy { $0.text.count <= 250 }, "chunks stay within the limit")
            try expect(chunks.dropLast().allSatisfy { $0.text.hasSuffix("。") }, "chunks end at a sentence end")
            try expectEqual(chunks.map(\.text).joined(), paragraph, "every character is kept in order")
        },
        TestCase(name: "chunker keeps the paragraph pause after a sentence end and trailing spaces") {
            var chunker = StreamingTextChunker(maxCharacters: 250)

            let chunks = chunker.append("A. B.  \n\nNo period here")

            try expectEqual(
                chunks,
                [StreamedTextChunk(text: "A. B.", endsParagraph: true)],
                "the sentence chunk ends the paragraph"
            )
        },
        TestCase(name: "chunker handles a long buffer with no boundary quickly") {
            var chunker = StreamingTextChunker(maxCharacters: 250)
            let clock = ContinuousClock()
            let started = clock.now

            let chunks = chunker.append(String(repeating: "wordies ", count: 125_000))

            try expect(chunks.count > 3_000, "a 1 MB paragraph is split, got \(chunks.count)")
            // Rescanning the whole buffer per chunk took minutes; bounded scans take well under this.
            try expect(clock.now - started < .seconds(10), "chunking 1 MB took \(clock.now - started)")
        },
        TestCase(name: "chunker flushes incomplete text after idle input") {
            var chunker = StreamingTextChunker(maxCharacters: 250)
            _ = chunker.append("No punctuation yet")

            try expectEqual(
                chunker.flush(),
                StreamedTextChunk(text: "No punctuation yet", endsParagraph: false, sourceRange: 0..<18),
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
                StreamedTextChunk(text: "🙂", endsParagraph: false, sourceRange: 250..<251),
                "Unicode remainder"
            )
        },
        TestCase(name: "chunker ranges point at each chunk in the received text") {
            let text = "  \n\nCafe\u{301} au lait. 👩‍👩‍👧 Family time!\r\n\r\n"
                + "これは長い段落です。Second   paragraph with   spaces.\n\n\n"
                + String(repeating: "word ", count: 80) + "end."
            let scalars = Array(text.unicodeScalars)
            // Pieces split at scalars, so one character can arrive in two appends.
            for pieceLength in [1, 2, 3, 7, 40, scalars.count] {
                var chunker = StreamingTextChunker(maxCharacters: 60)
                var chunks: [StreamedTextChunk] = []
                for start in stride(from: 0, to: scalars.count, by: pieceLength) {
                    let end = min(start + pieceLength, scalars.count)
                    chunks += chunker.append(String(String.UnicodeScalarView(scalars[start..<end])))
                }
                chunks += chunker.flush().map { [$0] } ?? []

                let spoken = Array(text.drop(while: \.isWhitespace).unicodeScalars)
                var previousEnd = 0
                for chunk in chunks {
                    guard let range = chunk.sourceRange else {
                        throw TestFailure(description: "chunk \"\(chunk.text)\" has no range")
                    }
                    try expect(range.lowerBound >= previousEnd, "ranges keep their order (piece \(pieceLength))")
                    try expectEqual(
                        String(String.UnicodeScalarView(spoken[range])),
                        chunk.text,
                        "range text for piece length \(pieceLength)"
                    )
                    previousEnd = range.upperBound
                }
                try expectEqual(previousEnd, spoken.count, "last range ends at the last scalar")
            }
        },
    ]
}
