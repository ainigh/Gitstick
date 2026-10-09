import Foundation
import GitstickCore

// Headless front-end to the same engine the menubar app uses.
//   gitstick sync  [path]   one sync cycle
//   gitstick watch [path]   keep a folder synced until Ctrl-C
//   gitstick pcs            list your PCs and drives on GitHub

setvbuf(stdout, nil, _IOLBF, 0)

let args = Array(CommandLine.arguments.dropFirst())
let command = args.first ?? "help"
let path = URL(fileURLWithPath: args.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let tokens = TokenProvider()

func describe(_ r: SyncReport) -> String {
    var lines: [String] = []
    if let c = r.committed { lines.append("✓ committed: \(c)") }
    if r.pulled { lines.append("↓ pulled remote changes") }
    if r.pushed { lines.append("↑ pushed") }
    for c in r.conflictCopies { lines.append("⚠︎ kept both versions → \(c)") }
    for h in r.heldBack { lines.append("✋ held back \(h.path): \(h.reason)") }
    switch r.status {
    case .idle: lines.append("● in sync")
    case .syncing: lines.append("… syncing")
    case .paused(let why): lines.append("⏸ paused: \(why)")
    case .divertedTo(let b): lines.append("↪︎ branch is protected; your work is on '\(b)'")
    case .error(let e): lines.append("✗ \(e)")
    }
    return lines.joined(separator: "\n")
}

switch command {
case "sync":
    let syncer = RepoSyncer(git: Git(repo: path, credentials: tokens))
    print(describe(syncer.syncOnce()))

case "watch":
    let syncer = RepoSyncer(git: Git(repo: path, credentials: tokens))
    syncer.onReport = { r in print("[\(Date())]\n" + describe(r)) }
    let watcher = makeWatcher(for: path)
    let debouncer = Debouncer { syncer.requestSync() }
    watcher.start { debouncer.poke() }
    syncer.requestSync()
    print("Watching \(path.path) — Ctrl-C to stop")
    dispatchMain()

case "pcs":
    let sema = DispatchSemaphore(value: 0)
    Task {
        do {
            for pc in try await GitHubCatalog(tokens: tokens).pcs() {
                print("\(pc.isOrg ? "🏢" : "💻") \(pc.login)")
                for d in pc.drives { print("   💾 \(d.name)\(d.isPrivate ? " 🔒" : "")\(d.canWrite ? "" : " (read-only)")") }
            }
        } catch { print("✗ \(error)") }
        sema.signal()
    }
    sema.wait()

default:
    print("""
    gitstick sync  [path]   run one sync cycle on a repo folder
    gitstick watch [path]   keep a repo folder synced (Ctrl-C to stop)
    gitstick pcs            list your GitHub accounts/orgs and their repos
    """)
}
