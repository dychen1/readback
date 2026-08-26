import Foundation
import VoicePipeKit

@main
enum VoicePipeCommand {
    static func main() async {
        do {
            let arguments = try VoicePipeArguments.parse(Array(CommandLine.arguments.dropFirst()))
            let client = VoicePipeClient(endpoint: arguments.endpoint)
            try await client.connect()

            var buffer = Data()
            for try await byte in FileHandle.standardInput.bytes {
                buffer.append(byte)
                guard let text = String(data: buffer, encoding: .utf8) else { continue }
                if buffer.count >= 32 || text.last?.isWhitespace == true || ".!?\n".contains(text.last ?? " ") {
                    try await client.append(text)
                    buffer.removeAll(keepingCapacity: true)
                }
            }
            if !buffer.isEmpty {
                try await client.append(String(decoding: buffer, as: UTF8.self))
            }
            try await client.finish()
        } catch {
            FileHandle.standardError.write(Data("voicepipe: \(error)\n".utf8))
            Foundation.exit(1)
        }
    }
}
