import Foundation
import ReadBackMac

func serviceHealthTests() -> [TestCase] {
    [
        TestCase(name: "clipboard health requires a ready backend and installed model") {
            let decoder = JSONDecoder()
            let ready = try decoder.decode(
                LocalServiceHealth.self,
                from: Data(#"{"status":"ok","backend":"ready","model_installed":true}"#.utf8)
            )
            let stopped = try decoder.decode(
                LocalServiceHealth.self,
                from: Data(#"{"status":"ok","backend":"stopped","model_installed":true}"#.utf8)
            )
            let missing = try decoder.decode(
                LocalServiceHealth.self,
                from: Data(#"{"status":"ok","backend":"ready","model_installed":false}"#.utf8)
            )

            try expect(ready.isReadyForSpeech, "ready health should allow clipboard speech")
            try expect(!stopped.isReadyForSpeech, "stopped backend should block clipboard speech")
            try expect(!missing.isReadyForSpeech, "missing model should block clipboard speech")
        },
    ]
}
