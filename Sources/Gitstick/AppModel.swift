import AppKit
import SwiftUI
import GitstickCore

@MainActor
final class AppModel: ObservableObject {
    @Published var pcs: [PC] = []
    @Published var statuses: [String: SyncStatus] = [:]
    @Published var reports: [String: SyncReport] = [:]
    @Published var signedInAs: String?
    @Published var loading = false
    @Published var message: String?
    @Published var busy: Set<String> = []
    @Published var plugged: [PluggedDrive] = []

    let tokens: TokenProvider
    let manager: DriveManager
    private var catalog: GitHubCatalog { GitHubCatalog(tokens: tokens) }

    init() {
        tokens = TokenProvider(explicit: { Keychain.read() })
        manager = DriveManager(tokens: tokens)
        manager.onStatus = { [weak self] id, status in
            Task { @MainActor in self?.statuses[id] = status }
        }
        manager.onReport = { [weak self] id, report in
            Task { @MainActor in self?.reports[id] = report }
        }
        plugged = manager.drives
        manager.startAll()
        Task { await refresh() }
    }

    // MARK: Catalog

    func refresh() async {
        loading = true
        defer { loading = false }
        do {
            let me = try await catalog.me()
            signedInAs = me.login
            manager.identity = (me.name ?? me.login, me.noreplyEmail)
            pcs = try await catalog.pcs()
            message = nil
        } catch {
            signedInAs = nil
            message = "\(error)"
        }
    }

    func signIn(token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        Keychain.write(t)
        tokens.invalidate()
        Task { await refresh(); manager.startAll() }
    }

    func signOut() {
        Keychain.delete()
        tokens.invalidate()
        signedInAs = nil
        pcs = []
    }

    // MARK: Drives

    func isPlugged(_ d: RemoteDrive) -> Bool { plugged.contains { $0.fullName == d.fullName } }

    func plugIn(_ d: RemoteDrive) {
        busy.insert(d.fullName)
        let manager = self.manager
        Task.detached {
            let result = Result { try manager.plugIn(d) }
            await MainActor.run {
                self.busy.remove(d.fullName)
                self.plugged = manager.drives
                if case .failure(let e) = result { self.message = "\(e)" }
                else { self.reveal(d.fullName) }
            }
        }
    }

    func eject(_ id: String) {
        busy.insert(id)
        let manager = self.manager
        Task.detached {
            let report = manager.eject(id)
            await MainActor.run {
                self.busy.remove(id)
                self.plugged = manager.drives
                self.statuses[id] = nil
                if let report, case .error(let e) = report.status {
                    self.message = "Ejected, but the last sync failed: \(e). Files are still in the folder."
                }
            }
        }
    }

    func syncNow(_ id: String) { manager.syncNow(id) }

    func reveal(_ id: String) {
        guard let d = plugged.first(where: { $0.fullName == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([d.url])
    }

    func openInEditor(_ id: String) {
        guard let d = plugged.first(where: { $0.fullName == id }) else { return }
        if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([d.url], withApplicationAt: vscode, configuration: .init())
        } else {
            NSWorkspace.shared.open(d.url)
        }
    }

    func openRoot() {
        try? FileManager.default.createDirectory(at: manager.root, withIntermediateDirectories: true)
        NSWorkspace.shared.open(manager.root)
    }

    func openOnGitHub(_ fullName: String) {
        if let url = URL(string: "https://github.com/\(fullName)") { NSWorkspace.shared.open(url) }
    }

    // MARK: Overall state for the menubar icon

    var menuSymbol: String {
        let all = plugged.compactMap { statuses[$0.fullName] }
        if all.contains(where: { if case .error = $0 { return true }; return false }) {
            return "externaldrive.badge.exclamationmark"
        }
        if all.contains(.syncing) { return "arrow.triangle.2.circlepath" }
        if all.contains(where: { if case .paused = $0 { return true }; return false }) {
            return "externaldrive.badge.minus"
        }
        return plugged.isEmpty ? "externaldrive" : "externaldrive.badge.checkmark"
    }
}

extension SyncStatus {
    var label: String {
        switch self {
        case .idle(let d):
            guard let d else { return "In sync" }
            let f = RelativeDateTimeFormatter()
            f.unitsStyle = .short
            return "Synced \(f.localizedString(for: d, relativeTo: Date()))"
        case .syncing: return "Syncing…"
        case .paused(let why): return "Paused — \(why)"
        case .divertedTo(let b): return "Read-only branch — saved to \(b)"
        case .error(let e): return e
        }
    }

    var color: Color {
        switch self {
        case .idle: return .green
        case .syncing: return .blue
        case .paused, .divertedTo: return .orange
        case .error: return .red
        }
    }
}
