import Foundation
import GitstickCore

// Headless front-end to the same engine the menubar app uses.
//   gitstick sync   [--manual] [--review] [path]   one sync cycle
//   gitstick watch  [--manual] [--review] [path]   keep a folder synced until Ctrl-C
//   gitstick commit [path]              manual mode's "Commit & Sync"
//   gitstick accept [path]              bring in the changes from GitHub that are waiting for your OK
//   gitstick decline [path]             hold them off until GitHub moves on
//   gitstick status [path]              local counts, no network
//   gitstick pcs                        list your PCs and drives on GitHub

setvbuf(stdout, nil, _IOLBF, 0)

var args = Array(CommandLine.arguments.dropFirst())
let manual = args.contains("--manual")
let review = args.contains("--review")
args.removeAll { $0 == "--manual" || $0 == "--review" }
let command = args.first ?? "help"
let path = URL(fileURLWithPath: args.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let tokens = TokenProvider()

func describe(_ l: LocalState) -> String {
    var bits: [String] = []
    if l.uncommitted > 0 { bits.append("\(l.uncommitted) uncommitted (\(l.staged) staged)") }
    if l.ahead > 0 { bits.append("\(l.ahead) to push") }
    if l.behind > 0 { bits.append("\(l.behind) to pull") }
    return bits.isEmpty ? "clean" : bits.joined(separator: ", ")
}

func describe(_ r: SyncReport) -> String {
    var lines: [String] = []
    if let c = r.committed { lines.append("✓ committed: \(c)") }
    if r.pulled { lines.append("↓ pulled remote changes") }
    if r.pushed { lines.append("↑ pushed") }
    for c in r.conflictCopies { lines.append("⚠︎ kept both versions → \(c)") }
    for h in r.heldBack { lines.append("✋ held back \(h.path): \(h.reason)") }
    switch r.status {
    case .incoming(let c):
        lines.append(c.declined ? "⏸ \(c.commits.count) commit(s) on GitHub held off (run `gitstick accept` to bring them in)"
                                : "❓ \(c.commits.count) commit(s) on GitHub are waiting for your OK — `gitstick accept` or `gitstick decline`")
        for commit in c.commits { lines.append("    \(commit.sha) \(commit.author): \(commit.subject)") }
        for f in c.files { lines.append("    \(f.status) \(f.path)\(c.alsoChangedHere.contains(f.path) ? "   (also changed here — both versions will be kept)" : "")") }
    case .idle: lines.append("● in sync")
    case .syncing: lines.append("… syncing")
    case .paused(let why): lines.append("⏸ paused: \(why)")
    case .waiting(let why): lines.append("⏳ \(why)")
    case .divertedTo(let b): lines.append("↪︎ branch is protected; your work is on '\(b)'")
    case .error(let e): lines.append("✗ \(e)")
    }
    lines.append("  local: \(describe(r.local))")
    return lines.joined(separator: "\n")
}

func syncer() -> RepoSyncer {
    let s = RepoSyncer(git: Git(repo: path, credentials: tokens), mode: manual ? .manual : .auto)
    s.pullPolicy = review ? .review : .automatic
    return s
}

switch command {
case "sync":
    print(describe(syncer().syncOnce()))

case "accept", "decline":
    // Decisions are stored in the repo (.git/gitstick/), so the next `sync --review` honors them.
    let s = RepoSyncer(git: Git(repo: path, credentials: tokens), mode: manual ? .manual : .auto)
    s.pullPolicy = .review
    let r = s.syncOnce()
    guard case .incoming(let c) = r.status else { print(describe(r)); break }
    if command == "accept" { s.record(.accepted, c.remoteHead); s.record(.declined, nil) } else { s.record(.declined, c.remoteHead) }
    print(describe(s.syncOnce()))

case "commit":
    let s = RepoSyncer(git: Git(repo: path, credentials: tokens), mode: .manual)
    print(describe(s.syncOnce(commitNow: true)))

case "status":
    do { print(describe(try syncer().localState())) } catch { print("✗ \(error)") }

case "watch":
    let s = syncer()
    s.onReport = { r in print("[\(Date())]\n" + describe(r)) }
    s.onLocalState = { l in if manual { print("  local: \(describe(l))") } }
    let watcher = makeWatcher(for: path)
    let soon = Debouncer { s.requestSync() }
    let local = Debouncer(quiet: 0.5, maxWait: 3) { s.requestLocalRefresh() }
    watcher.start { kind in
        if !manual || kind == .head { soon.poke() } else { local.poke() }
    }
    s.requestSync()
    print("Watching \(path.path) in \(manual ? "manual" : "auto") mode — Ctrl-C to stop")
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
    gitstick sync   [--manual] [--review] [path]   run one sync cycle on a repo folder
    gitstick watch  [--manual] [--review] [path]   keep a repo folder synced (Ctrl-C to stop)
    gitstick commit [path]              commit (staged, or everything) with a generated message, then sync
    gitstick accept [path]              bring in the GitHub changes that are waiting for your OK (--review)
    gitstick decline [path]             hold them off until GitHub moves on
    gitstick status [path]              uncommitted / ahead / behind, no network
    gitstick pcs                        list your GitHub accounts/orgs and their repos
    """)
}
