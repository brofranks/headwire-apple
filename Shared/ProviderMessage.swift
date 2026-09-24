import Foundation

/// The app-to-provider channel. Requests only read: a tunnel is started and
/// stopped through NetworkExtension, and no reply ever carries a private or
/// preshared key.
struct ProviderRequest: Codable, Equatable {
    static let currentVersion = 1

    var version = ProviderRequest.currentVersion
    /// A status field ("" for pretty print), `ip [-1|-4|-6]`, or `ping IP`.
    var statusField: String
}

struct ProviderReply: Codable, Equatable {
    var version = ProviderRequest.currentVersion
    var status: String?
    var error: String?

    /// The provider's answer: `status` asks the engine behind `handle`.
    static func answer(
        _ messageData: Data, handle: Int32?, status: (Int32, String) throws -> String
    ) -> ProviderReply {
        guard let request = try? JSONDecoder().decode(ProviderRequest.self, from: messageData),
            request.version == ProviderRequest.currentVersion
        else {
            return ProviderReply(error: "unsupported request")
        }
        guard let handle else {
            return ProviderReply(error: "not running")
        }
        do {
            return ProviderReply(status: try status(handle, request.statusField))
        } catch {
            return ProviderReply(error: error.localizedDescription)
        }
    }
}
