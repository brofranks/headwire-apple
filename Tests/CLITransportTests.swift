import XCTest

final class CLITransportTests: XCTestCase {
    /// A call from the worker thread the Go command line runs on. Static, so
    /// reaching it from a main-actor test sends nothing.
    private static func call(_ transport: CLITransport, _ line: String) async -> Result<String, Error> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: transport.call(line)) }
        }
    }

    @MainActor
    func testWorkerRequestsOnMainActor() async throws {
        var requests: [String] = []
        let transport = CLITransport { line in
            MainActor.assertIsolated()
            requests.append(line)
            return "reply: \(line)\n"
        }
        for line in ["", "ip -4", "ping 10.0.0.2"] {
            let result = await Self.call(transport, line)
            XCTAssertEqual(try result.get(), "reply: \(line)\n")
        }
        XCTAssertEqual(requests, ["", "ip -4", "ping 10.0.0.2"])
    }

    @MainActor
    func testTransportError() async {
        let transport = CLITransport { _ in throw TunnelController.Failure(errorDescription: "no profile is connected")
        }
        let result = await Self.call(transport, "ip")
        XCTAssertThrowsError(try result.get()) { XCTAssertEqual($0.localizedDescription, "no profile is connected") }
    }

    func testTimeoutConsumesReplyAndIgnoresLateCompletion() {
        let reply = CLIReply()
        XCTAssertThrowsError(try reply.wait(timeout: 0).get()) {
            XCTAssertEqual($0.localizedDescription, "provider request timed out")
        }
        reply.finish(.success("late"))
        XCTAssertThrowsError(try reply.wait(timeout: 0).get())
    }

    func testFirstCompletionWins() throws {
        let reply = CLIReply()
        reply.finish(.success("first"))
        reply.finish(.failure(TunnelController.Failure(errorDescription: "late error")))
        XCTAssertEqual(try reply.wait(timeout: 0).get(), "first")
    }
}
