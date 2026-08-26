import Foundation

public struct StreamingTextChunker: Sendable {
    private var buffer = ""
    private let maxCharacters: Int

    public init(maxCharacters: Int = 250) {
        precondition(maxCharacters > 0)
        self.maxCharacters = maxCharacters
    }

    public mutating func append(_ text: String) -> [String] {
        buffer.append(text)
        var chunks: [String] = []

        while let boundary = nextBoundary() {
            let rawChunk = String(buffer[..<boundary.contentEnd])
            buffer.removeSubrange(buffer.startIndex..<boundary.consumedEnd)
            trimLeadingWhitespace()

            let chunk = rawChunk.trimmingCharacters(in: .whitespacesAndNewlines)
            if !chunk.isEmpty {
                chunks.append(chunk)
            }
        }

        return chunks
    }

    public mutating func flush() -> String? {
        let chunk = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
        buffer.removeAll(keepingCapacity: true)
        return chunk.isEmpty ? nil : chunk
    }

    private func nextBoundary() -> Boundary? {
        let paragraph = paragraphBoundary()
        let sentence = sentenceBoundary()
        let natural = [paragraph, sentence]
            .compactMap { $0 }
            .min { buffer.distance(from: buffer.startIndex, to: $0.contentEnd) <
                buffer.distance(from: buffer.startIndex, to: $1.contentEnd) }

        if let natural {
            return natural
        }

        guard buffer.count >= maxCharacters else {
            return nil
        }
        let end = buffer.index(buffer.startIndex, offsetBy: maxCharacters)
        return Boundary(contentEnd: end, consumedEnd: end)
    }

    private func paragraphBoundary() -> Boundary? {
        guard let range = buffer.range(of: "\n\n") else {
            return nil
        }
        return Boundary(contentEnd: range.lowerBound, consumedEnd: range.upperBound)
    }

    private func sentenceBoundary() -> Boundary? {
        var index = buffer.startIndex
        while index < buffer.endIndex {
            let character = buffer[index]
            let after = buffer.index(after: index)
            if ".!?".contains(character),
               after == buffer.endIndex || buffer[after].isWhitespace {
                return Boundary(contentEnd: after, consumedEnd: after)
            }
            index = after
        }
        return nil
    }

    private mutating func trimLeadingWhitespace() {
        while let first = buffer.first, first.isWhitespace {
            buffer.removeFirst()
        }
    }

    private struct Boundary {
        let contentEnd: String.Index
        let consumedEnd: String.Index
    }
}
