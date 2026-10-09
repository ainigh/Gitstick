import AppKit
import Combine
import ServiceManagement
import SwiftUI
import GitstickCore

/// Something in a drive that you should know about. Stays in the menu until it's resolved or dismissed,
/// unlike a cycle's report, which the next (quiet) cycle replaces.
struct Attention: Identifiable, Equatable {
    enum Kind { case conflict, heldBack }
    let id: String
    let kind: Kind
    let path: String
    let text: String
}

@MainActor
final class AppModel: ObservableObject {
    @Published var pcs: [PC] = []
    @Published var statuses: [String: SyncStatus] = [:]
    @Published var reports: [String: SyncReport] = [:]
    @Published var local: [String: LocalState] = [:]
    @Published var attention: [String: [Attention]] = [:]
    @Published var signedInAs: String?
    @Published var loading = false
    @Published var message: String?
    @Published var busy: Set<String> = []
    @Published var plugged: [PluggedDrive] = []

    let tokens: TokenProvider
    let manager: DriveManager
    let notifier = Notifier()
    let updater: Updater
    private var bag = Set<AnyCancellable>()
    private var catalog: GitHubCatalog { GitHubCatalog(tokens: tokens) }

    init() {
        tokens = TokenProvider(explicit: { Keychain.read() })
        manager = DriveManager(tokens: tokens)
        updater = Updater(tokens: tokens)
        notifier.onOpen = { [weak self] id in Task { @MainActor in self?.reveal(id) } }
        // The menubar icon and the menu read the updater through this model.
        updater.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &bag)
        updater.beforeRelaunch = { [weak self] in self?.manager.stopAll() }
        manager.onStatus = { [weak self] id, status in
            Task { @MainActor in
                self?.statuses[id] = status
                if case .incoming(let changes) = status { self?.promptIfNew(changes, for: id) }
                self?.notifyIfNeeded(status, for: id)
            }
        }
        manager.onReport = { [weak self] id, report in
            Task { @MainActor in
                self?.reports[id] = report
                self?.noteAttention(from: report, for: id)
            }
        }
        manager.onLocalState = { [weak self] id, state in
            Task { @MainActor in self?.local[id] = state }
        }
        plugged = manager.drives
        manager.startAll()
        Task { await refresh() }
        updater.start()
        noteVersionChange()
    }

    /// "Gitstick updated to 0.3.12", once, the first time a new copy runs.
    private func noteVersionChange() {
        guard Updater.isBundled else { return }
        let key = "lastRunVersion", now = Updater.currentVersion
        let previous = UserDefaults.standard.string(forKey: key)
        UserDefaults.standard.set(now, forKey: key)
        guard let previous, previous != now else { return }
        notifier.notify(drive: "", key: "updated:\(now)", title: "Gitstick updated to \(now)",
                        body: "Your drives are syncing as before.")
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
    func commitAndSync(_ id: String) { manager.commitAndSync(id) }

    // MARK: Reviewing incoming changes

    /// Remote heads we've already popped a dialog for. One question per change on GitHub.
    private var prompted: Set<String> = []

    func setPullPolicy(_ policy: PullPolicy, for id: String) {
        manager.setPullPolicy(policy, for: id)
        plugged = manager.drives
    }

    func acceptIncoming(_ changes: IncomingChanges, for id: String) { manager.acceptIncoming(changes, for: id) }
    func declineIncoming(_ changes: IncomingChanges, for id: String) { manager.declineIncoming(changes, for: id) }
    func reconsiderIncoming(_ id: String) { manager.reconsiderIncoming(id) }

    /// The compare page on GitHub for exactly these changes.
    func openCompareOnGitHub(_ changes: IncomingChanges, for id: String) {
        guard let d = plugged.first(where: { $0.fullName == id }),
              let local = Git(repo: d.url).value(["rev-parse", "HEAD"]),
              let url = URL(string: "https://github.com/\(id)/compare/\(local)...\(changes.remoteHead)") else { return }
        NSWorkspace.shared.open(url)
    }

    private func promptIfNew(_ changes: IncomingChanges, for id: String) {
        let key = "\(id)@\(changes.remoteHead)"
        guard !changes.declined, !prompted.contains(key) else { return }
        prompted.insert(key)
        review(changes, for: id)
    }

    /// The one dialog in Gitstick: what GitHub wants to put in your folder, and a yes or a no.
    func review(_ changes: IncomingChanges, for id: String) {
        let name = plugged.first(where: { $0.fullName == id })?.name ?? id
        let alert = NSAlert()
        alert.messageText = "\(changes.commits.count == 1 ? "1 change" : "\(changes.commits.count) changes") on GitHub for “\(name)”"
        alert.informativeText = Self.describe(changes)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Accept")
        alert.addButton(withTitle: "Not Now")
        alert.addButton(withTitle: "Open on GitHub")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: acceptIncoming(changes, for: id)
        case .alertSecondButtonReturn: declineIncoming(changes, for: id)
        default: openCompareOnGitHub(changes, for: id)      // stays pending; the menu keeps the buttons
        }
    }

    static func describe(_ changes: IncomingChanges) -> String {
        var lines: [String] = []
        for c in changes.commits.prefix(8) { lines.append("• \(c.author): \(c.subject)") }
        if changes.commits.count > 8 { lines.append("• … and \(changes.commits.count - 8) more") }
        lines.append("")
        for f in changes.files.prefix(12) {
            let verb: String
            switch f.status {
            case "A": verb = "adds"
            case "D": verb = "deletes"
            case "R": verb = "moves"
            default: verb = "changes"
            }
            lines.append("\(verb) \(f.path)" + (changes.alsoChangedHere.contains(f.path) ? "  ⚠︎ also changed on this Mac" : ""))
        }
        if changes.files.count > 12 { lines.append("… and \(changes.files.count - 12) more files") }
        if !changes.alsoChangedHere.isEmpty {
            lines.append("")
            lines.append("Accepting keeps both versions of the ⚠︎ files: GitHub's keeps the name, yours is saved next to it.")
        }
        lines.append("")
        lines.append("Not Now leaves everything as it is. Your own changes keep syncing, and you'll be asked again when GitHub moves on.")
        return lines.joined(separator: "\n")
    }

    func setMode(_ mode: SyncMode, for id: String) {
        manager.setMode(mode, for: id)
        plugged = manager.drives
        reports[id] = nil
    }

    // MARK: What needs you

    /// Notified once per piece of news, so a held-back file isn't announced again every minute.
    private var announced: Set<String> = []

    private func driveName(_ id: String) -> String { plugged.first(where: { $0.fullName == id })?.name ?? id }

    private func noteAttention(from report: SyncReport, for id: String) {
        var items = attention[id] ?? []
        let name = driveName(id)

        // Held-back files are re-reported on every cycle, so the report is the truth: replace.
        let held = report.heldBack.map {
            Attention(id: "held:\($0.path)", kind: .heldBack, path: $0.path,
                      text: "✋ \($0.path) not synced: \($0.reason.description)")
        }
        let heldBefore = Set(items.filter { $0.kind == .heldBack }.map(\.id))
        items.removeAll { $0.kind == .heldBack }
        items.append(contentsOf: held)
        for h in report.heldBack where !heldBefore.contains("held:\(h.path)") {
            announce("held:\(id):\(h.path)", drive: id, title: "\(h.path) stays on this Mac",
                     body: "It \(h.reason.description), so Gitstick didn't put it on GitHub. Everything else in “\(name)” synced.")
        }

        // A conflict copy is news once; it stays listed until you dismiss it.
        for copy in report.conflictCopies where !items.contains(where: { $0.id == "conflict:\(copy)" }) {
            let copyName = (copy as NSString).lastPathComponent
            items.append(Attention(id: "conflict:\(copy)", kind: .conflict, path: copy, text: "⚠︎ Kept both versions: \(copyName)"))
            announce("conflict:\(id):\(copy)", drive: id, title: "Kept both versions in “\(name)”",
                     body: "A file changed here and on GitHub. GitHub's keeps the name; yours is saved as “\(copyName)”.")
        }
        attention[id] = items
    }

    private func notifyIfNeeded(_ status: SyncStatus, for id: String) {
        let name = driveName(id)
        switch status {
        case .divertedTo(let branch):
            announce("diverted:\(id):\(branch)", drive: id, title: "“\(name)” is protected on GitHub",
                     body: "Your changes are safe on the branch “\(branch)”. Open a pull request on GitHub to bring them in.")
        case .error(let why) where !why.hasPrefix("Offline"):
            announce("error:\(id):\(why)", drive: id, title: "“\(name)” isn't syncing", body: why)
        default: break
        }
    }

    private func announce(_ key: String, drive id: String, title: String, body: String) {
        guard !announced.contains(key) else { return }
        announced.insert(key)
        notifier.notify(drive: id, key: key, title: title, body: body)
    }

    func dismissAttention(_ attentionID: String, for id: String) {
        attention[id]?.removeAll { $0.id == attentionID }
    }

    /// Shows the file (a conflict copy, a held-back file) in Finder.
    func reveal(_ id: String, path: String) {
        guard let d = plugged.first(where: { $0.fullName == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([d.url.appendingPathComponent(path)])
    }

    // MARK: Launch at login

    /// Only a bundled .app can register itself (see Scripts/make-app.sh); `swift run` can't.
    static let canLaunchAtLogin = Bundle.main.bundleIdentifier != nil

    var launchAtLogin: Bool { Self.canLaunchAtLogin && SMAppService.mainApp.status == .enabled }

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            message = "Couldn't change Launch at Login: \(error.localizedDescription)"
        }
        objectWillChange.send()
    }

    func reveal(_ id: String) {
        guard let d = plugged.first(where: { $0.fullName == id }) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([d.url])
    }

    func openInEditor(_ id: String) {
        guard let d = plugged.first(where: { $0.fullName == id }) else { return }
        if let vscode = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.microsoft.VSCode") {
            NSWorkspace.shared.open([d.url], withApplicationAt: vscode, configuration: NSWorkspace.OpenConfiguration())
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

    /// The drive icon, with its badge for the drives' state. It turns solid when an update is ready.
    var menuSymbol: String {
        let symbol = driveSymbol
        guard updater.available != nil, symbol.hasPrefix("externaldrive") else { return symbol }
        return "externaldrive.fill" + String(symbol.dropFirst("externaldrive".count))
    }

    private var driveSymbol: String {
        let all = plugged.compactMap { statuses[$0.fullName] }
        if all.contains(where: { if case .error = $0 { return true }; return false }) {
            return "externaldrive.badge.exclamationmark"
        }
        if all.contains(.syncing) { return "arrow.triangle.2.circlepath" }
        if all.contains(where: { if case .incoming(let c) = $0 { return !c.declined }; return false }) {
            return "externaldrive.badge.questionmark"
        }
        if all.contains(where: {
            switch $0 { case .paused, .waiting: return true; default: return false }
        }) {
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
        case .incoming(let c):
            let n = c.commits.count == 1 ? "1 change" : "\(c.commits.count) changes"
            return c.declined ? "\(n) on GitHub held off" : "\(n) on GitHub waiting for your OK"
        case .paused(let why): return "Paused — \(why)"
        case .waiting(let why): return why
        case .divertedTo(let b): return "Read-only branch — saved to \(b)"
        case .error(let e): return e
        }
    }

    var color: Color {
        switch self {
        case .idle: return .green
        case .syncing: return .blue
        case .paused: return .gray
        case .waiting, .divertedTo, .incoming: return .orange
        case .error: return .red
        }
    }
}

extension SyncMode {
    var title: String {
        switch self {
        case .auto: return "Auto"
        case .manual: return "Manual"
        case .paused: return "Paused"
        }
    }
    var explanation: String {
        switch self {
        case .auto: return "Commits, pulls and pushes everything for you"
        case .manual: return "You commit; Gitstick pulls when safe and pushes your commits"
        case .paused: return "Hands off — nothing is synced"
        }
    }
}
