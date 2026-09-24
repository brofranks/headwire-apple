import Foundation

/// The Go CLI runs on a worker thread and calls this synchronous adapter.
/// NetworkExtension stays on the main actor, and only the worker waits for it.
final class CLITransport: @unchecked Sendable {
    private let request: @MainActor (String) async throws -> String

    init(request: @escaping @MainActor (String) async throws -> String) {
        self.request = request
    }

    func call(_ line: String, timeout: TimeInterval = 5) -> Result<String, Error> {
        let reply = CLIReply()
        Task { @MainActor in
            do { reply.finish(.success(try await request(line))) } catch { reply.finish(.failure(error)) }
        }
        return reply.wait(timeout: timeout)
    }
}

/// One terminal result, protected by the condition across the worker and main
/// actor. Timeout consumes the result slot too, so late replies are harmless.
final class CLIReply: @unchecked Sendable {
    private let condition = NSCondition()
    private var result: Result<String, Error>?

    func finish(_ result: Result<String, Error>) {
        condition.lock()
        defer { condition.unlock() }
        guard self.result == nil else { return }
        self.result = result
        condition.signal()
    }

    func wait(timeout: TimeInterval) -> Result<String, Error> {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while result == nil {
            if !condition.wait(until: deadline), result == nil {
                result = .failure(Diagnostics.timedOut)
            }
        }
        return result!
    }
}
