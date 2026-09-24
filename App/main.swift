import AppKit
import NetworkExtension

@MainActor
func run(_ args: [String]) async throws {
    switch Launch.command(args) {
    case .list:
        for profile in try await InstalledProfiles.all() {
            print("\(profile.name)\t\(describe(profile.status))")
        }
    case .up(let name):
        try await InstalledProfiles.up(name) {
            FileHandle.standardError.write(Data("headwire: \(SystemExtension.approvalNeeded)\n".utf8))
        }
    case .down: try await TunnelController.down(managers: NETunnelProviderManager.loadAllFromPreferences())
    // LaunchServices brings a running instance forward instead of starting
    // a second one. A fresh launch arrives as the GUI (Launch.isGUI).
    case .rungui:
        _ = try await NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    case .shared:
        var manager: NETunnelProviderManager?
        let transport = CLITransport { line in
            if manager == nil { manager = try await InstalledProfiles.active() }
            return try await TunnelController.status(manager!, field: line)
        }
        exit(await runCLI(args, transport: transport))
    }
}

if Launch.isGUI(
    arguments: CommandLine.arguments, environment: ProcessInfo.processInfo.environment,
    bundleID: Bundle.main.bundleIdentifier!)
{
    MainActor.assumeIsolated {
        NSApplication.shared.setActivationPolicy(.accessory)
        withExtendedLifetime(StatusMenu()) { NSApplication.shared.run() }
    }
    exit(0)
}

Task {
    do {
        try await run(Array(CommandLine.arguments.dropFirst()))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("headwire: \(error.localizedDescription)\n".utf8))
        exit(1)
    }
}
// NetworkExtension and SystemExtensions call back on the main queue.
dispatchMain()
