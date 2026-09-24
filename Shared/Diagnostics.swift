import Foundation
import os

/// The one log and the one error type both apps and the provider report with.
enum Diagnostics {
    static let log = Logger(subsystem: Identifiers.product, category: "headwire")

    /// NetworkExtension carries an NSError's description to the app, but a
    /// Swift error arrives there as an opaque domain and code, so every failure
    /// the provider reports is built here. The log is where a root system
    /// extension's own account of a failure survives.
    static func failure(_ description: String) -> NSError {
        log.error("\(description, privacy: .public)")
        return NSError(
            domain: Identifiers.product, code: 1,
            userInfo: [NSLocalizedDescriptionKey: description])
    }

    /// A request that outlived its deadline: the provider is busy or gone.
    static var timedOut: NSError { failure("provider request timed out") }
}
