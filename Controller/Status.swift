import NetworkExtension
#if os(macOS)
    import ServiceManagement
#endif

/// The `list` column for a profile's state.
func describe(_ status: NEVPNStatus?) -> String {
    switch status {
    case nil: return "unregistered"
    case .connected: return "connected"
    case .connecting: return "connecting"
    case .disconnecting: return "disconnecting"
    case .reasserting: return "reasserting"
    case .invalid: return "invalid"
    default: return "disconnected"
    }
}

/// What the menu bar item shows for the profiles, free of AppKit: one entry
/// each, marked while its tunnel is up or changing, and the summary the
/// status item reports to accessibility.
struct MenuState: Equatable {
    enum Mark {
        case on, mixed, off
    }
    struct Entry: Equatable {
        var title: String
        var mark: Mark
    }

    var entries: [Entry]
    var summary: String
    var connected: Bool { entries.contains { $0.mark == .on } }

    @MainActor
    init(_ profiles: [TunnelController.Profile]) {
        entries = profiles.map { profile in
            switch profile.status {
            case .connected: Entry(title: profile.name, mark: .on)
            case .connecting, .disconnecting, .reasserting: Entry(title: profile.name, mark: .mixed)
            default: Entry(title: profile.name, mark: .off)
            }
        }
        let connected = entries.filter { $0.mark == .on }.map(\.title)
        let transitioning = entries.filter { $0.mark == .mixed }.map(\.title)
        summary =
            !connected.isEmpty
            ? "Connected: \(connected.joined(separator: ", "))"
            : !transitioning.isEmpty ? "Connection changing: \(transitioning.joined(separator: ", "))" : "Not connected"
    }
}

#if os(macOS)

    /// What the Launch at Login item shows for a login-item status, free of
    /// AppKit. A status with no action is one the user cannot change here.
    struct LoginItemState: Equatable {
        var title = "Launch at Login"
        var on = false
        var actionable = true
    }

    extension LoginItemState {
        /// The memberwise initializer stays available to tests.
        init(_ status: SMAppService.Status) {
            self.init()
            switch status {
            case .enabled:
                on = true
            case .notRegistered, .notFound:
                break
            case .requiresApproval:
                title = "Launch at Login: Approval Required…"
            @unknown default:
                title = "Launch at Login: Unavailable"
                actionable = false
            }
        }
    }

#endif
