import Combine
import NetworkExtension
import SwiftUI
import UniformTypeIdentifiers

@main
struct HeadwireApp: App {
    var body: some Scene {
        WindowGroup { ProfileList() }
    }
}

@MainActor
final class Tunnels: ObservableObject {
    @Published var failure: String?
    private lazy var list = TunnelList(load: ImportedProfiles.all) { [weak self] in
        self?.objectWillChange.send()
    }
    var profiles: [TunnelController.Profile] { list.profiles }

    init() {
        attempt {}
    }

    /// Runs work, shows its error, and reloads: work may add or remove
    /// profiles.
    func attempt(_ work: @escaping @MainActor () async throws -> Void) {
        Task {
            do {
                try await list.attempt(work)
            } catch {
                failure = error.localizedDescription
            }
            objectWillChange.send()
        }
    }
}

/// The main screen: the profiles, each with its connect toggle.
struct ProfileList: View {
    @StateObject private var tunnels = Tunnels()
    @State private var importing = false
    @State private var pasting = false
    @State private var licensing = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(tunnels.profiles, id: \.keychainReference) { profile in
                    NavigationLink {
                        StatusView(manager: profile.manager as! NETunnelProviderManager)
                    } label: {
                        Toggle(
                            profile.name,
                            isOn: Binding(
                                get: { profile.status == .connected || profile.status == .connecting },
                                set: { on in
                                    tunnels.attempt {
                                        if on {
                                            try await ImportedProfiles.up(profile.manager!)
                                        } else {
                                            try await TunnelController.down(profile.manager!)
                                        }
                                    }
                                }))
                    }
                }
                .onDelete { offsets in
                    let doomed = offsets.map { tunnels.profiles[$0].manager! }
                    tunnels.attempt {
                        for manager in doomed {
                            try await manager.removeFromPreferences()
                        }
                    }
                }
            }
            .overlay {
                if tunnels.profiles.isEmpty {
                    Text("Import a Headwire configuration.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Headwire")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Menu {
                        Button("Licenses") { licensing = true }
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Menu {
                        Button("Import File") { importing = true }
                        Button("Paste Text") { pasting = true }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .navigationDestination(isPresented: $licensing) { LicensesView() }
            // A .conf has no declared type, so any file is offered.
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item]) { result in
                tunnels.attempt {
                    let url = try result.get()
                    guard url.startAccessingSecurityScopedResource() else {
                        throw TunnelController.Failure(errorDescription: "cannot read \(url.lastPathComponent)")
                    }
                    defer { url.stopAccessingSecurityScopedResource() }
                    try await ImportedProfiles.add(
                        url.deletingPathExtension().lastPathComponent, text: String(contentsOf: url, encoding: .utf8))
                }
            }
            .sheet(isPresented: $pasting) {
                PasteView { name, text in
                    tunnels.attempt { try await ImportedProfiles.add(name, text: text) }
                }
            }
            .alert(
                "Headwire", isPresented: Binding(get: { tunnels.failure != nil }, set: { _ in tunnels.failure = nil })
            ) {
                Button("OK") {}
            } message: {
                Text(tunnels.failure ?? "")
            }
        }
    }
}

/// Imports a configuration from pasted text.
struct PasteView: View {
    var add: (String, String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var text = ""

    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextEditor(text: $text)
                    .font(.system(.footnote, design: .monospaced))
                    .frame(minHeight: 240)
            }
            .navigationTitle("New Profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        add(name, text)
                        dismiss()
                    }
                }
            }
        }
    }
}

/// `headwire show` from the running provider.
struct StatusView: View {
    let manager: NETunnelProviderManager
    @State private var output = ""

    var body: some View {
        ScrollView {
            Text(output)
                .font(.system(.footnote, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .navigationTitle(manager.localizedDescription ?? "")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Refreshes until the view goes away and the task is cancelled.
            while !Task.isCancelled {
                do {
                    output =
                        manager.status == .connected
                        ? try await TunnelController.status(manager, field: "") : "not connected"
                } catch {
                    output = error.localizedDescription
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

/// The bundled third-party notices.
struct LicensesView: View {
    // One entry per license keeps the whole 93 KB off the first frame: a
    // lazy stack lays out only the sections on screen.
    @State private var sections: [String] = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                ForEach(Array(sections.enumerated()), id: \.offset) { _, section in
                    Text(section)
                        .font(.footnote)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .navigationTitle("Licenses")
        .task {
            do {
                let text = try String(
                    contentsOf: Bundle.main.url(forResource: "ThirdPartyLicenses", withExtension: "txt")!,
                    encoding: .utf8)
                let parts = text.components(separatedBy: "\nSources: ")
                sections = [parts[0]] + parts.dropFirst().map { "Sources: " + $0 }
            } catch {
                sections = [error.localizedDescription]
            }
        }
    }
}
