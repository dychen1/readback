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

func wait(for duration: Duration) async throws {
    let clock = ContinuousClock()
    try await clock.sleep(until: clock.now.advanced(by: duration))
}

@main
enum ReadBackTestRunner {
    static func main() async {
        let tests = configurationTests()
            + modelCatalogTests()
            + modelAssetsTests()
            + modelLibraryTests()
            + modelManagerTests()
            + backgroundModelWarmupTests()
            + modelManagerPresentationTests()
            + readBackActivityGateTests()
            + modelWorkspaceTests()
            + wavEncoderTests()
            + inferenceSmokeTests()
            + mlxSpeechModelSessionTests()
            + speechRuntimeAdapterTests()
            + voiceCatalogTests()
            + audioPlayerTests()
            + streamChunkerTests()
            + streamProtocolTests()
            + speechCoordinatorTests()
            + speechReplayCacheTests()
            + clipboardChangeMonitorTests()
            + speechMemoryPolicyTests()
            + readBackSkillClientTests()
            + readBackSkillInstallerTests()
            + readBackSkillPresentationTests()
            + voicePipeTests()
            + voicePipeTextSpeakerTests()
            + clipboardReadBackTests()
            + clipboardPlaybackDecisionTests()
            + serviceHealthTests()
            + readBackAPITests()
            + readBackWebSocketTests()
            + runtimePathsTests()
            + singleInstanceLockTests()
        let filter = ProcessInfo.processInfo.environment["READBACK_TEST_FILTER"]
        let selectedTests = filter.map { needle in
            tests.filter { $0.name.localizedCaseInsensitiveContains(needle) }
        } ?? tests
        let exclude = ProcessInfo.processInfo.environment["READBACK_TEST_EXCLUDE"]
        let runnableTests = exclude.map { needle in
            selectedTests.filter { !$0.name.localizedCaseInsensitiveContains(needle) }
        } ?? selectedTests
        var failures = 0

        for test in runnableTests {
            do {
                try await test.body()
                print("PASS \(test.name)")
            } catch {
                failures += 1
                print("FAIL \(test.name): \(error)")
            }
        }

        print("\(runnableTests.count - failures) passed, \(failures) failed")
        if failures > 0 {
            Foundation.exit(1)
        }
    }
}
