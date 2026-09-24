import XCTest

final class LaunchTests: XCTestCase {
    func testLaunchServicesLaunchIsTheGUI() {
        let id = "dev.brof.headwire"
        let byLaunchServices = ["XPC_SERVICE_NAME": "application.\(id).1890181.1890187"]
        XCTAssertTrue(
            Launch.isGUI(
                arguments: ["/Applications/Headwire.app/Contents/MacOS/Headwire"], environment: byLaunchServices,
                bundleID: id))
        // A bare shell launch must reach the shared command line, which prints
        // usage.
        XCTAssertFalse(Launch.isGUI(arguments: ["Headwire"], environment: [:], bundleID: id))
        XCTAssertFalse(Launch.isGUI(arguments: ["Headwire"], environment: ["XPC_SERVICE_NAME": "0"], bundleID: id))
        XCTAssertFalse(Launch.isGUI(arguments: ["Headwire", "list"], environment: byLaunchServices, bundleID: id))
    }

    func testVerbsAndHelpDispatch() {
        XCTAssertEqual(Launch.command(["list"]), .list)
        XCTAssertEqual(Launch.command(["up", "home"]), .up("home"))
        XCTAssertEqual(Launch.command(["up"]), .up("main"))
        XCTAssertEqual(Launch.command(["down"]), .down)
        XCTAssertEqual(Launch.command(["rungui"]), .rungui)
        // The shared command line answers help and everything else, including
        // a bare `help`, which is a valid profile name.
        for arguments in [
            [], ["show"], ["up", "-h"], ["up", "--help"], ["list", "-h"], ["down", "x"], ["help", "up"],
        ] {
            XCTAssertEqual(Launch.command(arguments), .shared, arguments.joined(separator: " "))
        }
        XCTAssertEqual(Launch.command(["up", "help"]), .up("help"))
    }
}
