import Foundation
import ReadBackMac

@MainActor
private final class ClipboardMonitorFixture {
    var revision = 1
    var invalidations = 0
    var continuation: CheckedContinuation<Void, Never>?
    var shouldBlock = false

    func invalidate() async {
        invalidations += 1
        if shouldBlock { await withCheckedContinuation { continuation = $0 } }
    }
}

func clipboardChangeMonitorTests() -> [TestCase] {
    [
        TestCase(name: "clipboard revision changes invalidate replay without reading text") { @MainActor in
            let fixture = ClipboardMonitorFixture()
            let monitor = ClipboardChangeMonitor(changeCount: { fixture.revision }) {
                await fixture.invalidate()
            }
            await monitor.checkForChanges()
            try expectEqual(fixture.invalidations, 0, "unchanged clipboard")
            fixture.revision = 2
            await monitor.checkForChanges()
            await monitor.checkForChanges()
            try expectEqual(fixture.invalidations, 1, "one revision, one invalidation")
            fixture.revision = 3
            await monitor.checkForChanges()
            try expectEqual(fixture.invalidations, 2, "another copy, even if the text were identical")
        },
        TestCase(name: "clipboard checks await an invalidation already in progress") { @MainActor in
            let fixture = ClipboardMonitorFixture()
            fixture.shouldBlock = true
            let monitor = ClipboardChangeMonitor(changeCount: { fixture.revision }) {
                await fixture.invalidate()
            }
            fixture.revision += 1
            let first = Task { await monitor.checkForChanges() }
            while fixture.continuation == nil { await Task.yield() }
            var secondFinished = false
            let second = Task { await monitor.checkForChanges(); secondFinished = true }
            await Task.yield()
            try expect(!secondFinished, "shortcut must wait for the pending purge")
            fixture.continuation?.resume()
            fixture.continuation = nil
            await first.value
            await second.value
            try expect(secondFinished, "shortcut continues after purge")
            try expectEqual(fixture.invalidations, 1, "no duplicate purge")
        },
    ]
}
