import AppKit
import SwiftUI
import GitstickCore

struct MenuView: View {
    @EnvironmentObject var model: AppModel
    @State private var tokenField = ""
    @State private var filter = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            updateBanner
            if model.signedInAs == nil && !model.loading {
                signIn
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        if !model.plugged.isEmpty { pluggedSection }
                        pcsSection
                    }
                    .padding(12)
                }
                .frame(height: 420)
            }
            if let msg = model.message {
                Divider()
                Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(3).padding(10)
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Image(systemName: "externaldrive.connected.to.line.below").font(.title3)
            VStack(alignment: .leading, spacing: 1) {
                Text("Gitstick").font(.headline)
                Text(model.signedInAs.map { "Signed in as \($0)" } ?? "Not signed in")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if model.loading { ProgressView().controlSize(.small) }
            Button { Task { await model.refresh() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless).help("Refresh")
        }
        .padding(12)
    }

    // MARK: Updates

    /// Shown only when there's something to say: a release is ready, it's installing, or it failed.
    @ViewBuilder private var updateBanner: some View {
        switch model.updater.state {
        case .available(let release):
            HStack(spacing: 8) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Gitstick \(release.version?.description ?? release.tag) is ready").font(.subheadline.bold())
                    Text(release.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Update") { model.updater.install() }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(Color.accentColor.opacity(0.08))
            Divider()
        case .installing(let step):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step).font(.caption)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
        case .failed(let why):
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                Text(why).font(.caption).lineLimit(3)
                Spacer()
                Button("Try Again") { model.updater.check(userInitiated: true) }.controlSize(.small)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
        default:
            EmptyView()
        }
    }

    private var versionLine: String {
        let v = "Version \(Updater.currentVersion)" + (Updater.currentCommit.map { " (\($0))" } ?? "")
        switch model.updater.state {
        case .checking: return v + " · checking…"
        case .upToDate: return v + " · up to date"
        default: return v
        }
    }

    // MARK: Sign in

    private var signIn: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect GitHub").font(.subheadline.bold())
            Text("If you use the GitHub CLI, run `gh auth login` and hit refresh. Or paste a token with the `repo` scope:")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("ghp_… or github_pat_…", text: $tokenField)
                .textFieldStyle(.roundedBorder)
                .onSubmit { model.signIn(token: tokenField); tokenField = "" }
            HStack {
                Button("Create a token…") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/settings/tokens/new?scopes=repo,read:org&description=Gitstick")!)
                }
                Spacer()
                Button("Connect") { model.signIn(token: tokenField); tokenField = "" }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(12)
    }

    // MARK: Plugged in

    private var pluggedSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ON THIS MAC").font(.caption2.bold()).foregroundStyle(.secondary)
            ForEach(model.plugged) { d in PluggedRow(drive: d) }
        }
    }

    // MARK: PCs

    private var pcsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("PCs").font(.caption2.bold()).foregroundStyle(.secondary)
                Spacer()
                TextField("Filter", text: $filter).textFieldStyle(.roundedBorder).frame(width: 120).controlSize(.small)
            }
            ForEach(model.pcs) { pc in
                let drives = pc.drives.filter { filter.isEmpty || $0.name.localizedCaseInsensitiveContains(filter) }
                if !drives.isEmpty || filter.isEmpty {
                    DisclosureGroup {
                        ForEach(drives) { d in RemoteRow(drive: d) }
                        if drives.isEmpty { Text("No drives").font(.caption).foregroundStyle(.secondary) }
                    } label: {
                        Label("\(pc.login)  ·  \(pc.drives.count)", systemImage: pc.isOrg ? "building.2" : "desktopcomputer")
                    }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Button("Open Gitstick Folder") { model.openRoot() }
            Spacer()
            Menu {
                Text(versionLine)
                if Updater.isBundled {
                    Button("Check for Updates…") { model.updater.check(userInitiated: true) }
                } else {
                    Text("Updates need the built app (Scripts/make-app.sh)")
                }
                Divider()
                if AppModel.canLaunchAtLogin {
                    Toggle("Launch at Login", isOn: Binding(
                        get: { model.launchAtLogin },
                        set: { model.setLaunchAtLogin($0) }
                    ))
                    Divider()
                }
                if model.signedInAs != nil { Button("Sign Out") { model.signOut() } }
                Button("Quit Gitstick") { model.manager.stopAll(); NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

/// A drive that's plugged in: status, mode, actions.
struct PluggedRow: View {
    @EnvironmentObject var model: AppModel
    let drive: PluggedDrive

    var body: some View {
        let status = model.statuses[drive.fullName]
        let local = model.local[drive.fullName] ?? LocalState()
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Circle().fill(status?.color ?? .gray).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(drive.name).font(.body)
                        if drive.mode != .auto { ModeBadge(mode: drive.mode) }
                        if drive.pullPolicy == .review {
                            Image(systemName: "hand.raised").font(.caption2).foregroundStyle(.secondary)
                                .help("Changes from GitHub wait for your OK")
                        }
                    }
                    Text("\(drive.owner) · \(status?.label ?? "Starting…")")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if model.busy.contains(drive.fullName) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.reveal(drive.fullName) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                    actions
                }
            }

            // Manual mode lives here: what's pending, and the one-click commit.
            if drive.mode != .auto && (local.uncommitted > 0 || local.ahead > 0 || local.behind > 0) {
                HStack(spacing: 8) {
                    Text(Self.summary(local)).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if drive.mode == .manual && local.uncommitted > 0 {
                        Button(local.staged > 0 ? "Commit Staged & Sync" : "Commit & Sync") {
                            model.commitAndSync(drive.fullName)
                        }
                        .controlSize(.small)
                        .help(local.staged > 0
                              ? "Commits only the \(local.staged) staged file(s) with a generated message"
                              : "Commits all changes with a generated message, then syncs")
                    }
                }
                .padding(.leading, 16)
            }

            // Incoming changes waiting for a yes (pull policy: review).
            if case .incoming(let changes)? = status {
                HStack(spacing: 8) {
                    Button("Review…") { model.review(changes, for: drive.fullName) }
                    Button("Accept") { model.acceptIncoming(changes, for: drive.fullName) }
                    if !changes.declined { Button("Not Now") { model.declineIncoming(changes, for: drive.fullName) } }
                    Spacer()
                }
                .controlSize(.small)
                .padding(.leading, 16)
            }

            // What needs you: held-back files (until they're gone) and conflict copies (until dismissed).
            ForEach(model.attention[drive.fullName] ?? []) { a in
                HStack(spacing: 4) {
                    Text(a.text).font(.caption2).foregroundStyle(.orange).lineLimit(2)
                    Spacer()
                    Button { model.reveal(drive.fullName, path: a.path) } label: { Image(systemName: "magnifyingglass") }
                        .buttonStyle(.borderless).controlSize(.small).help("Show in Finder")
                    if a.kind == .conflict {
                        Button { model.dismissAttention(a.id, for: drive.fullName) } label: { Image(systemName: "xmark.circle") }
                            .buttonStyle(.borderless).controlSize(.small).help("Dismiss")
                    }
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private var actions: some View {
        Menu {
            Button("Show in Finder") { model.reveal(drive.fullName) }
            Button("Open in Editor") { model.openInEditor(drive.fullName) }
            Button("Open on GitHub") { model.openOnGitHub(drive.fullName) }
            Divider()
            Picker("Mode", selection: Binding(
                get: { drive.mode },
                set: { model.setMode($0, for: drive.fullName) }
            )) {
                ForEach(SyncMode.allCases, id: \.self) { m in
                    Text("\(m.title) — \(m.explanation)").tag(m)
                }
            }
            Toggle("Ask Before Pulling", isOn: Binding(
                get: { drive.pullPolicy == .review },
                set: { model.setPullPolicy($0 ? .review : .automatic, for: drive.fullName) }
            ))
            Divider()
            if drive.mode == .manual { Button("Commit & Sync") { model.commitAndSync(drive.fullName) } }
            if drive.mode != .paused { Button("Sync Now") { model.syncNow(drive.fullName) } }
            Button("Eject") { model.eject(drive.fullName) }
        } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton).fixedSize()
    }

    static func summary(_ l: LocalState) -> String {
        var bits: [String] = []
        if l.uncommitted > 0 { bits.append(l.staged > 0 ? "\(l.uncommitted) changed (\(l.staged) staged)" : "\(l.uncommitted) changed") }
        if l.ahead > 0 { bits.append("\(l.ahead) to push") }
        if l.behind > 0 { bits.append("\(l.behind) to pull") }
        return bits.joined(separator: " · ")
    }
}

struct ModeBadge: View {
    let mode: SyncMode
    var body: some View {
        Text(mode.title.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(mode == .paused ? Color.gray.opacity(0.25) : Color.accentColor.opacity(0.18)))
            .foregroundStyle(mode == .paused ? Color.secondary : Color.accentColor)
            .help(mode.explanation)
    }
}

/// A drive on GitHub that may or may not be plugged in.
struct RemoteRow: View {
    @EnvironmentObject var model: AppModel
    let drive: RemoteDrive

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: model.isPlugged(drive) ? "externaldrive.fill" : "externaldrive")
                .foregroundStyle(model.isPlugged(drive) ? Color.accentColor : .secondary)
            Text(drive.name).lineLimit(1)
            if drive.isPrivate { Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.secondary) }
            if !drive.canWrite || drive.archived {
                Text("read-only").font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            if model.busy.contains(drive.fullName) {
                ProgressView().controlSize(.small)
            } else if model.isPlugged(drive) {
                Button("Eject") { model.eject(drive.fullName) }.controlSize(.small)
            } else {
                Button("Plug In") { model.plugIn(drive) }.controlSize(.small)
            }
        }
        .padding(.leading, 4)
    }
}
