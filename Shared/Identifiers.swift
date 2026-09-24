import Foundation

enum Identifiers {
    /// The product identifier: log subsystem, error domain, keychain service.
    static let product = "dev.brof.headwire"
    /// The extension's bundle ID is the app's plus ".extension"
    /// (Config/*.xcconfig).
    static var providerExtension: String { Bundle.main.bundleIdentifier! + ".extension" }
}

/// On macOS a profile is the name of a root-owned /etc/headwire/<name>.conf.
/// The name is all the app ever hands the root provider, and the Go bridge
/// applies the same rule again before it builds the path. iOS names keychain
/// items by the same rule.
enum ProfileName {
    static let configDirectory = "/etc/headwire"

    /// The profile an omitted name selects.
    static let defaultName = "main"

    static func isValid(_ name: String) -> Bool {
        name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    }

    /// The profiles among a configuration directory's entries: each valid
    /// `NAME.conf`, sorted.
    static func installed(_ files: [String]) -> [String] {
        files.filter { $0.hasSuffix(".conf") }.map { String($0.dropLast(5)) }.filter(isValid).sorted()
    }
}
