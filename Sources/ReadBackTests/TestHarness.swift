import Foundation

struct TestCase {
    let name: String
    let body: () async throws -> Void
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    guard condition() else {
        throw TestFailure(description: message)
    }
}

func expectEqual<Value: Equatable>(
    _ actual: @autoclosure () -> Value,
    _ expected: Value,
    _ message: String
) throws {
    let value = actual()
    guard value == expected else {
        throw TestFailure(description: "\(message): expected \(expected), got \(value)")
    }
}

@main
enum ReadBackTestRunner {
    static func main() async {
        let tests = configurationTests()
            + voiceCatalogTests()
            + audioPlayerTests()
            + modelStoreTests()
            + streamChunkerTests()
            + streamProtocolTests()
            + backendCommandTests()
            + mlxBackendClientTests()
            + speechCoordinatorTests()
            + voicePipeTests()
            + voicePipeTextSpeakerTests()
            + clipboardReadBackTests()
            + clipboardPlaybackDecisionTests()
            + serviceHealthTests()
            + readBackAPITests()
            + readBackWebSocketTests()
            + runtimePathsTests()
        var failures = 0

        for test in tests {
            do {
                try await test.body()
                print("PASS \(test.name)")
            } catch {
                failures += 1
                print("FAIL \(test.name): \(error)")
            }
        }

        print("\(tests.count - failures) passed, \(failures) failed")
        if failures > 0 {
            Foundation.exit(1)
        }
    }
}
