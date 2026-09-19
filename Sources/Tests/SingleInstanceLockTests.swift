import Foundation
import ReadBackCore

func singleInstanceLockTests() -> [TestCase] {
    [
        TestCase(name: "second process lock cannot acquire the same instance") {
            let lockFileURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("readback-instance-(UUID().uuidString).lock")
            defer { try? FileManager.default.removeItem(at: lockFileURL) }

            let first = SingleInstanceLock(lockFileURL: lockFileURL)
            let second = SingleInstanceLock(lockFileURL: lockFileURL)

            try expect(first.acquire(), "first process lock should acquire")
            try expect(!second.acquire(), "second process lock should be rejected")
        },
    ]
}
