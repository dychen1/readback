import Foundation

public struct StreamedTextChunk: Equatable, Sendable {
    public let text: String
    public let endsParagraph: Bool
    /// The position of `text` in all the text that the chunker received, as Unicode scalar
    /// offsets. Offsets start at the first character that is not whitespace. Scalar counts
    /// add up across `append` calls, also when one character arrives in two calls.
    public let sourceRange: Range<Int>?

    public init(text: String, endsParagraph: Bool, sourceRange: Range<Int>? = nil) {
        self.text = text
        self.endsParagraph = endsParagraph
        self.sourceRange = sourceRange
    }
}

public struct StreamingTextChunker: Sendable {
    private var buffer = ""
    private let maxCharacters: Int
    /// The number of received Unicode scalars before `buffer`, from the first character that
    /// is not whitespace.
    private var consumedScalars = 0
    private var hasReceivedText = false

    public init(maxCharacters: Int = 250) {
        precondition(maxCharacters > 0)
        self.maxCharacters = maxCharacters
    }

    public mutating func append(_ text: String) -> [StreamedTextChunk] {
        buffer.append(text)
        if !hasReceivedText {
            buffer = String(buffer.drop(while: \.isWhitespace))
            hasReceivedText = !buffer.isEmpty
        }
        var chunks: [StreamedTextChunk] = []

        while let boundary = nextBoundary() {
            if let chunk = makeChunk(buffer[..<boundary.contentEnd], endsParagraph: boundary.endsParagraph) {
                chunks.append(chunk)
            }
            consumedScalars += buffer[..<boundary.consumedEnd].unicodeScalars.count
            buffer.removeSubrange(buffer.startIndex..<boundary.consumedEnd)
            trimLeadingWhitespace()
        }

        return chunks
    }

    public mutating func flush() -> StreamedTextChunk? {
        let chunk = makeChunk(buffer[...], endsParagraph: false)
        consumedScalars += buffer.unicodeScalars.count
        buffer.removeAll(keepingCapacity: true)
        return chunk
    }

    private func makeChunk(_ raw: Substring, endsParagraph: Bool) -> StreamedTextChunk? {
        let leading = raw.prefix(while: \.isWhitespace)
        var text = raw.dropFirst(leading.count)
        while let last = text.last, last.isWhitespace {
            text.removeLast()
        }
        guard !text.isEmpty else { return nil }
        let start = consumedScalars + leading.unicodeScalars.count
        return StreamedTextChunk(
            text: String(text),
            endsParagraph: endsParagraph,
            sourceRange: start..<(start + text.unicodeScalars.count)
        )
    }

    /// ASCII marks end a sentence when whitespace or the end of the received text follows.
    /// Stream clients may send a whole sentence with no commit and expect it to play.
    private static let terminators: Set<Character> = [".", "!", "?"]
    /// Full-width marks end a sentence with no space after them, as in CJK text.
    private static let fullWidthTerminators: Set<Character> = ["。", "！", "？"]

    private func nextBoundary() -> Boundary? {
        let paragraph = paragraphBoundary()
        let sentence = sentenceBoundary()
        switch (paragraph, sentence) {
        case let (paragraph?, sentence?):
            // A sentence end followed only by whitespace before the paragraph break ends
            // the paragraph too, so the paragraph pause is kept.
            if paragraph.contentEnd <= sentence.contentEnd
                || buffer[sentence.contentEnd..<paragraph.contentEnd].allSatisfy(\.isWhitespace)
            {
                return paragraph
            }
            return sentence
        case let (paragraph?, nil):
            return paragraph
        case let (nil, sentence?):
            return sentence
        case (nil, nil):
            break
        }

        guard let end = buffer.index(buffer.startIndex, offsetBy: maxCharacters, limitedBy: buffer.endIndex)
        else {
            return nil
        }
        // Cut at the last space in the window so a word is not split, if there is one.
        if let space = buffer[..<end].lastIndex(where: \.isWhitespace), space > buffer.startIndex {
            return Boundary(contentEnd: space, consumedEnd: space, endsParagraph: false)
        }
        return Boundary(contentEnd: end, consumedEnd: end, endsParagraph: false)
    }

    /// Searches only the first `maxCharacters` characters (plus the break itself), so a
    /// long buffer is not rescanned for every chunk.
    private func paragraphBoundary() -> Boundary? {
        let searchEnd = buffer.index(buffer.startIndex, offsetBy: maxCharacters + 2, limitedBy: buffer.endIndex)
            ?? buffer.endIndex
        guard let range = buffer[..<searchEnd].range(of: "\n\n"),
              buffer.distance(from: buffer.startIndex, to: range.lowerBound) <= maxCharacters
        else {
            return nil
        }
        return Boundary(
            contentEnd: range.lowerBound,
            consumedEnd: range.upperBound,
            endsParagraph: true
        )
    }

    /// Returns the last sentence end within `maxCharacters`, so short sentences are read
    /// together. Stops scanning at the limit.
    private func sentenceBoundary() -> Boundary? {
        var index = buffer.startIndex
        var length = 0
        var candidate: Boundary?
        while index < buffer.endIndex, length < maxCharacters {
            let character = buffer[index]
            let after = buffer.index(after: index)
            length += 1
            let endsSentence = Self.fullWidthTerminators.contains(character)
                || (Self.terminators.contains(character)
                    && (after == buffer.endIndex || buffer[after].isWhitespace))
            if endsSentence {
                candidate = Boundary(contentEnd: after, consumedEnd: after, endsParagraph: false)
            }
            index = after
        }
        return candidate
    }

    private mutating func trimLeadingWhitespace() {
        while let first = buffer.first, first.isWhitespace {
            buffer.removeFirst()
            consumedScalars += first.unicodeScalars.count
        }
    }

    private struct Boundary {
        let contentEnd: String.Index
        let consumedEnd: String.Index
        let endsParagraph: Bool
    }
}
