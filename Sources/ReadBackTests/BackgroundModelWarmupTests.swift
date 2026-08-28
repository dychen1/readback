import ReadBackCore

private actor WarmupProbe {
    private var invocationCount = 0
    private var started = false
    private var cancelled = false

    func run() async {
        invocationCount += 1
        started = true
        do {
            try await Task.sleep(for: .seconds(60))
        } catch is CancellationError {
            cancelled = true
        } catch {}
    }

    func waitUntilStarted() async {
        while !started {
            await Task.yield()
        }
    }

    func waitUntilCancelled() async {
        while !cancelled {
            await Task.yield()
        }
    }

    func invocations() -> Int { invocationCount }
}

func backgroundModelWarmupTests() -> [TestCase] {
    [
        TestCase(name: "background model warm-up starts once without blocking launch") {
            let probe = WarmupProbe()
            let warmup = BackgroundModelWarmup {
                await probe.run()
            }

            await warmup.start()
            await warmup.start()
            await probe.waitUntilStarted()

            let invocations = await probe.invocations()
            try expectEqual(invocations, 1, "warm-up invocations")
            await warmup.cancel()
        },
        TestCase(name: "background model warm-up cancels with app shutdown") {
            let probe = WarmupProbe()
            let warmup = BackgroundModelWarmup {
                await probe.run()
            }

            await warmup.start()
            await probe.waitUntilStarted()
            await warmup.cancel()
            await probe.waitUntilCancelled()

            let invocations = await probe.invocations()
            try expectEqual(invocations, 1, "warm-up invocations")
        },
    ]
}
