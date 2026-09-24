import XCTest

/// The shared Go CLI as the app runs it, over a fake transport. Reaching a
/// reply at all proves the arrangement the app depends on: the CLI runs off
/// the main thread and blocks there while the main actor answers, so a
/// deadlock fails these tests by timing out rather than in the menu bar.
/// Arguments exclude the program name, as App/main.swift passes them.
@MainActor
final class CLITests: XCTestCase {
    private var lines: [String] = []
    private var reply = "peer: abc\n"
    private var failure: Error?

    private lazy var transport = CLITransport { [unowned self] line in
        XCTAssertTrue(Thread.isMainThread, "the transport answers on the main actor")
        self.lines.append(line)
        if let failure = self.failure { throw failure }
        return self.reply
    }

    private func exitCode(_ args: [String]) async -> Int32 {
        await runCLI(args, transport: transport)
    }

    func testVersionNeedsNoRunningNode() async {
        let code = await exitCode(["version"])
        XCTAssertEqual(code, 0)
        XCTAssertEqual(lines, [])
    }

    /// The bridge registers the macOS verbs, so their help resolves here even
    /// though App/main.swift dispatches the verbs themselves.
    func testHelpCoversTheHostsOwnVerbs() async {
        let up = await exitCode(["help", "up"])
        let nonsense = await exitCode(["help", "nonsense"])
        XCTAssertEqual([up, nonsense], [0, 2])
        XCTAssertEqual(lines, [])
    }

    func testRequestsReachTheTransportAsTheirProtocolLines() async {
        let show = await exitCode(["show"])
        let ip = await exitCode(["ip", "-4"])
        XCTAssertEqual([show, ip], [0, 0])
        XCTAssertEqual(lines, ["", "ip -4"])
    }

    func testArgumentsAreRejectedBeforeAnyRequest() async {
        let flag = await exitCode(["ip", "-9"])
        let field = await exitCode(["show", "no-such-field"])
        XCTAssertEqual([flag, field], [2, 2])
        XCTAssertEqual(lines, [])
    }

    func testATransportFailureIsReportedAsAFailedCommand() async {
        failure = Diagnostics.failure("no profile is connected")
        let code = await exitCode(["show"])
        XCTAssertEqual(code, 1)
        XCTAssertEqual(lines, [""])
    }
}
