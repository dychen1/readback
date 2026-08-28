import Foundation
import ReadBackSkill

private actor ControlledSkillTransport: ReadBackSkillTransport {
    enum Reply: Sendable {
        case response(status: Int, body: Data)
        case failure(URLError)
    }

    private var replies: [Reply]
    private var requests: [URLRequest] = []

    init(_ replies: [Reply]) {
        self.replies = replies
    }

    func data(for request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !replies.isEmpty else {
            throw TestFailure(description: "unexpected skill client request")
        }
        switch replies.removeFirst() {
        case .response(let status, let body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            return (body, response)
        case .failure(let error):
            throw error
        }
    }

    func receivedRequests() -> [URLRequest] {
        requests
    }
}

private actor ControlledSkillLauncher: ReadBackAppLaunching {
    private var count = 0

    func launch() async throws {
        count += 1
    }

    func launchCount() -> Int {
        count
    }
}

private struct ImmediateSkillClock: ReadBackSkillClock {
    func sleep(for duration: Duration) async throws {}
}

func readBackSkillClientTests() -> [TestCase] {
    [
        TestCase(name: "skill client sends only adapted input to the active local model") {
            let transport = ControlledSkillTransport([
                .response(
                    status: 200,
                    body: Data(
                        #"{"status":"ok","runtime":"ready","active_model":"kokoro","model_installed":true}"#.utf8
                    )
                ),
                .response(status: 200, body: Data(#"{"ok":true}"#.utf8)),
            ])
            let launcher = ControlledSkillLauncher()
            let client = ReadBackSkillClient(
                transport: transport,
                launcher: launcher,
                clock: ImmediateSkillClock()
            )

            try await client.play("spoken brief")

            let requests = await transport.receivedRequests()
            try expectEqual(requests.count, 2, "health and playback request count")
            try expectEqual(requests[0].httpMethod, "GET", "health method")
            try expectEqual(requests[0].url?.path, "/health", "health path")
            try expectEqual(requests[1].httpMethod, "POST", "play method")
            try expectEqual(requests[1].url?.path, "/play", "play path")
            let object = try JSONSerialization.jsonObject(with: requests[1].httpBody!)
            guard let body = object as? [String: String] else {
                throw TestFailure(description: "play body must be a string dictionary")
            }
            try expectEqual(body, ["input": "spoken brief"], "fixed play body")
            let launchCount = await launcher.launchCount()
            try expectEqual(launchCount, 0, "ready app launch count")
        },
        TestCase(name: "skill client launches ReadBack after a loopback connection failure") {
            let transport = ControlledSkillTransport([
                .failure(URLError(.cannotConnectToHost)),
                .response(
                    status: 200,
                    body: Data(
                        #"{"status":"starting","runtime":"starting","active_model":"kokoro","model_installed":true}"#.utf8
                    )
                ),
                .response(
                    status: 200,
                    body: Data(
                        #"{"status":"ok","runtime":"ready","active_model":"kokoro","model_installed":true}"#.utf8
                    )
                ),
                .response(status: 200, body: Data(#"{"ok":true}"#.utf8)),
            ])
            let launcher = ControlledSkillLauncher()
            let client = ReadBackSkillClient(
                transport: transport,
                launcher: launcher,
                clock: ImmediateSkillClock(),
                readinessAttempts: 3
            )

            try await client.play("start the app")

            let launchCount = await launcher.launchCount()
            try expectEqual(launchCount, 1, "app launch count")
            let requests = await transport.receivedRequests()
            try expectEqual(requests.map(\.url?.path), ["/health", "/health", "/health", "/play"], "request order")
        },
        TestCase(name: "skill client stops when the active model never becomes ready") {
            let notReady = Data(
                #"{"status":"starting","runtime":"starting","active_model":"kokoro","model_installed":true}"#.utf8
            )
            let transport = ControlledSkillTransport([
                .response(status: 200, body: notReady),
                .response(status: 200, body: notReady),
            ])
            let client = ReadBackSkillClient(
                transport: transport,
                launcher: ControlledSkillLauncher(),
                clock: ImmediateSkillClock(),
                readinessAttempts: 2
            )

            do {
                try await client.play("never ready")
                throw TestFailure(description: "not-ready service should time out")
            } catch ReadBackSkillClientError.serviceNotReady {
            }

            let requests = await transport.receivedRequests()
            try expectEqual(requests.count, 2, "bounded health request count")
        },
        TestCase(name: "skill client rejects empty input without network or launch work") {
            let transport = ControlledSkillTransport([])
            let launcher = ControlledSkillLauncher()
            let client = ReadBackSkillClient(
                transport: transport,
                launcher: launcher,
                clock: ImmediateSkillClock()
            )

            do {
                try await client.play(" \n\t")
                throw TestFailure(description: "empty input should fail")
            } catch ReadBackSkillClientError.emptyInput {
            }

            let requestCount = await transport.receivedRequests().count
            let launchCount = await launcher.launchCount()
            try expectEqual(requestCount, 0, "empty request count")
            try expectEqual(launchCount, 0, "empty launch count")
        },
        TestCase(name: "skill client command rejects every option") {
            do {
                _ = try ReadBackSkillCommandInput.parse(
                    arguments: ["--model", "kokoro"],
                    data: Data("brief".utf8)
                )
                throw TestFailure(description: "command options should fail")
            } catch ReadBackSkillClientError.argumentsNotAllowed {
            }
        },
        TestCase(name: "skill client command rejects non-UTF-8 standard input") {
            do {
                _ = try ReadBackSkillCommandInput.parse(
                    arguments: [],
                    data: Data([0xFF, 0xFE])
                )
                throw TestFailure(description: "invalid UTF-8 should fail")
            } catch ReadBackSkillClientError.invalidInputEncoding {
            }
        },
    ]
}
