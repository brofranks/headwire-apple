import Foundation

/// Whether this process is the menu bar item or the command line. The same
/// executable is both: LaunchServices (Finder, `open`, login items) launches
/// the bundle with XPC_SERVICE_NAME set to application.<bundle id>.<pids>,
/// while a shell leaves it unset or "0".
enum Launch {
    /// The macOS tunnel verbs. Everything else, their help included, is the
    /// headwire command line the Linux daemon has.
    enum Command: Equatable {
        case list, up(String), down, rungui, shared
    }

    static func isGUI(arguments: [String], environment: [String: String], bundleID: String) -> Bool {
        arguments.count == 1 && (environment["XPC_SERVICE_NAME"] ?? "").contains(bundleID)
    }

    /// `up -h` is for the shared command line to answer. A bare `help` stays
    /// a profile name, which -h and --help cannot be.
    static func command(_ arguments: [String]) -> Command {
        switch (arguments.first, arguments.count) {
        case ("list", 1): return .list
        case ("up", 1): return .up(ProfileName.defaultName)
        case ("up", 2) where !["-h", "--help"].contains(arguments[1]): return .up(arguments[1])
        case ("down", 1): return .down
        case ("rungui", 1): return .rungui
        default: return .shared
        }
    }
}
