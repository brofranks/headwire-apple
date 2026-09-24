import AppKit
import ServiceManagement
import os

/// The menu bar item: one entry per /etc/headwire profile, checked while its
/// tunnel is up, and clicking one is `up` or `down`.
@MainActor
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let loginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLogin), keyEquivalent: "")
    private lazy var list = TunnelList(load: InstalledProfiles.all) { [weak self] in self?.render() }

    override init() {
        super.init()
        loginItem.target = self
        item.button?.image = NSImage(named: "StatusIcon")
        item.button?.setAccessibilityLabel("Headwire")
        item.button?.setAccessibilityValue("Status unavailable")
        item.menu = menu
        menu.delegate = self
        reload()
    }

    func menuWillOpen(_ menu: NSMenu) {
        reload()
    }

    private func reload() {
        renderLogin()
        Task {
            do {
                try await list.reload()
                render()
            } catch {
                show([NSMenuItem(title: error.localizedDescription, action: nil, keyEquivalent: "")])
                item.button?.setAccessibilityValue("Status unavailable")
            }
        }
    }

    private func render() {
        let state = MenuState(list.profiles)
        show(
            state.entries.isEmpty
                ? [NSMenuItem(title: "No profiles in \(ProfileName.configDirectory)", action: nil, keyEquivalent: "")]
                : state.entries.map(entry))
        item.button?.appearsDisabled = !state.connected
        item.button?.setAccessibilityValue(state.summary)
    }

    private func show(_ entries: [NSMenuItem]) {
        let items =
            entries + [
                .separator(), loginItem, .separator(),
                NSMenuItem(title: "Quit Headwire", action: #selector(NSApplication.terminate), keyEquivalent: "q"),
            ]
        // Replacing the items of a menu that is already on screen leaves an
        // empty row below the last one, and opening the menu reloads it into
        // the same items whenever no profile changed.
        if items.elementsEqual(menu.items, by: { $0.title == $1.title && $0.state == $1.state }) { return }
        menu.items = items
    }

    private func renderLogin() {
        let state = LoginItemState(SMAppService.mainApp.status)
        loginItem.title = state.title
        loginItem.state = state.on ? .on : .off
        loginItem.action = state.actionable ? #selector(toggleLogin) : nil
    }

    @objc private func toggleLogin() {
        attempt {
            switch SMAppService.mainApp.status {
            case .enabled:
                try await SMAppService.mainApp.unregister()
            // A first registration can report notFound even for the installed
            // app.
            case .notRegistered, .notFound:
                try SMAppService.mainApp.register()
            case .requiresApproval:
                break
            @unknown default:
                return
            }
            if SMAppService.mainApp.status == .requiresApproval {
                SMAppService.openSystemSettingsLoginItems()
            }
        }
    }

    private func entry(_ profile: MenuState.Entry) -> NSMenuItem {
        let entry = NSMenuItem(title: profile.title, action: #selector(toggle), keyEquivalent: "")
        entry.target = self
        switch profile.mark {
        case .on: entry.state = .on
        case .mixed: entry.state = .mixed
        case .off: entry.state = .off
        }
        return entry
    }

    @objc private func toggle(_ sender: NSMenuItem) {
        attempt {
            if sender.state == .off {
                try await InstalledProfiles.up(sender.title) {
                    // The delegate reports approval on the main queue, but the
                    // alert belongs to the main actor, and a detached task
                    // keeps the modal from blocking the activation.
                    Task { @MainActor in Self.alert(SystemExtension.approvalNeeded) }
                }
            } else {
                try await TunnelController.down(try await InstalledProfiles.registered(sender.title))
            }
        }
    }

    private func attempt(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await list.attempt(work)
            } catch {
                Self.alert(error.localizedDescription)
            }
            renderLogin()
            render()
        }
    }

    private static func alert(_ message: String) {
        // An alert is gone once dismissed. The log is where an activation or
        // transition failure survives, as it does for the provider.
        Diagnostics.log.error("\(message, privacy: .public)")
        let alert = NSAlert()
        alert.messageText = "Headwire"
        alert.informativeText = message
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
