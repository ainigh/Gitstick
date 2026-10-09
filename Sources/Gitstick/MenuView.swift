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
                if model.signedInAs != nil { Button("Sign Out") { model.signOut() } }
                Button("Quit Gitstick") { model.manager.stopAll(); NSApp.terminate(nil) }
            } label: { Image(systemName: "gearshape") }
                .menuStyle(.borderlessButton).fixedSize()
        }
        .buttonStyle(.borderless)
        .padding(10)
    }
}

/// A drive that's plugged in: status + actions.
struct PluggedRow: View {
    @EnvironmentObject var model: AppModel
    let drive: PluggedDrive

    var body: some View {
        let status = model.statuses[drive.fullName]
        let report = model.reports[drive.fullName]
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Circle().fill(status?.color ?? .gray).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 1) {
                    Text(drive.name).font(.body)
                    Text("\(drive.owner) · \(status?.label ?? (drive.autoSync ? "Starting…" : "Read-only"))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if model.busy.contains(drive.fullName) {
                    ProgressView().controlSize(.small)
                } else {
                    Button { model.reveal(drive.fullName) } label: { Image(systemName: "folder") }
                        .buttonStyle(.borderless).help("Show in Finder")
                    Menu {
                        Button("Show in Finder") { model.reveal(drive.fullName) }
                        Button("Open in Editor") { model.openInEditor(drive.fullName) }
                        Button("Open on GitHub") { model.openOnGitHub(drive.fullName) }
                        Divider()
                        Button("Sync Now") { model.syncNow(drive.fullName) }
                        Button("Eject") { model.eject(drive.fullName) }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if let report {
                ForEach(report.heldBack, id: \.path) { h in
                    Text("✋ \(h.path) not synced: \(h.reason.description)")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
                ForEach(report.conflictCopies, id: \.self) { c in
                    Text("⚠︎ Kept both versions: \((c as NSString).lastPathComponent)")
                        .font(.caption2).foregroundStyle(.orange).lineLimit(2)
                }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
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
