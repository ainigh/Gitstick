import Foundation

/// How much Gitstick does on a drive.
public enum SyncMode: String, Codable, CaseIterable, Sendable {
    /// Gitstick commits everything, pulls, merges, pushes. Drop files and walk away.
    case auto
    /// You commit (VS Code, terminal, or one-click "Commit & Sync"). Gitstick never touches your
    /// working tree or index on its own; it only pulls when that's safe and pushes your commits.
    case manual
    /// Gitstick does nothing to the repo. Status is still shown.
    case paused
}

/// Whether changes from GitHub land in the folder on their own, or wait for your OK.
public enum PullPolicy: String, Codable, CaseIterable, Sendable {
    /// Remote changes are merged as soon as they're seen.
    case automatic
    /// Remote changes are fetched and summarized, then wait until you accept them. Your own work
    /// is still committed and pushed on its own, as long as GitHub isn't ahead of you.
    case review
}

/// What GitHub has that this folder doesn't, summarized for a human to accept or decline.
public struct IncomingChanges: Equatable, Sendable {
    public struct Commit: Equatable, Sendable {
        public let sha: String
        public let author: String
        public let subject: String
    }
    /// The remote commit these changes end at. A decision (accept / decline) is about this exact
    /// commit; if GitHub moves on, you're asked again.
    public let remoteHead: String
    public let commits: [Commit]
    /// Status letter (A/M/D/R…) and path, as `git diff --name-status` reports them.
    public let files: [(status: Character, path: String)]
    /// Of those, the files that also changed on this Mac since the two sides diverged.
    /// Accepting keeps both versions (I2); these are the ones that will get a conflict copy.
    public let alsoChangedHere: [String]
    /// You said "not now" to exactly these changes. They stay on GitHub, nothing nags, and the
    /// next time GitHub moves you're asked about the new state.
    public let declined: Bool

    public static func == (l: IncomingChanges, r: IncomingChanges) -> Bool {
        l.remoteHead == r.remoteHead && l.declined == r.declined && l.commits == r.commits
            && l.alsoChangedHere == r.alsoChangedHere
            && l.files.map { "\($0.status)\($0.path)" } == r.files.map { "\($0.status)\($0.path)" }
    }
}

public enum SyncStatus: Equatable, Sendable {
    case idle(lastSync: Date?)
    case syncing
    /// Changes on GitHub are waiting for your OK (pull policy is `.review`). Nothing was merged.
    case incoming(IncomingChanges)
    /// A human or tool is mid-operation in this repo, or sync is switched off. We wait.
    case paused(String)
    /// Remote changes are ready but pulling them now would touch your uncommitted work.
    /// Nothing was changed; the next cycle after you commit/clean up will pull them.
    case waiting(String)
    /// Branch is protected / read-only: local work is safe on a side branch.
    case divertedTo(branch: String)
    /// GitHub can't be reached right now. Local work is committed (auto mode) and waits; the next
    /// cycle tries again. Not an error: laptops go offline all the time.
    case offline(lastSync: Date?)
    case error(String)
}

/// What's going on in the folder right now. Cheap to compute, refreshed on every file change.
public struct LocalState: Equatable, Sendable {
    public var uncommitted = 0   // changed / new / deleted files not yet committed (incl. staged)
    public var staged = 0        // of which staged
    public var ahead = 0         // local commits not on GitHub yet
    public var behind = 0        // GitHub commits not here yet (as of the last fetch)
    public init() {}
}

public struct SyncReport: Equatable, Sendable {
    public var committed: String? = nil          // subject of the commit Gitstick made, if any
    public var pulled = false                     // remote changes were integrated
    public var pushed = false
    public var conflictCopies: [String] = []
    public var heldBack: [HeldFile] = []
    public var local = LocalState()
    public var status: SyncStatus = .idle(lastSync: nil)
}

/// One plugged-in drive's sync engine.
///
///     guard  ->  snapshot  ->  fetch  ->  integrate (merge, keep-both)  ->  push
///                 (auto, or
///               "Commit & Sync")
///
/// Invariants (see ARCHITECTURE.md):
///  1. Gitstick's own commits happen BEFORE anything remote touches the working tree.
///  2. Nothing ever prompts. Every decision has a default.
///  3. Never rewrite published history: no force-push, no rebase, no amend.
///  4. If a human is operating git in this repo, back off.
///  5. Cycles are serialized per repo; requests during a cycle coalesce into one follow-up.
///  10. Manual mode: Gitstick never commits on its own, never alters your index, and only merges
///      when git can do so without touching any uncommitted file. Otherwise: `.waiting`.
public final class RepoSyncer: @unchecked Sendable {
    public let git: Git
    public var gatekeeper = Gatekeeper()
    public let deviceName: String
    public var remote = "origin"
    public var maxPushAttempts = 3

    public var mode: SyncMode {
        get { lock.lock(); defer { lock.unlock() }; return _mode }
        set { lock.lock(); _mode = newValue; lock.unlock() }
    }

    public var pullPolicy: PullPolicy {
        get { lock.lock(); defer { lock.unlock() }; return _pullPolicy }
        set { lock.lock(); _pullPolicy = newValue; lock.unlock() }
    }

    public var onStatus: ((SyncStatus) -> Void)?
    public var onReport: ((SyncReport) -> Void)?
    public var onLocalState: ((LocalState) -> Void)?

    private let queue: DispatchQueue
    private let lock = NSLock()
    private var _mode: SyncMode
    private var _pullPolicy: PullPolicy = .automatic
    private var running = false
    private var pending = false
    private var wantCommit = false
    public private(set) var lastSync: Date?

    public init(git: Git, mode: SyncMode = .auto, deviceName: String = RepoSyncer.defaultDeviceName) {
        self.git = git
        self._mode = mode
        self.deviceName = deviceName
        self.queue = DispatchQueue(label: "gitstick.sync.\(git.repo.lastPathComponent)", qos: .utility)
    }

    public static var defaultDeviceName: String {
        let raw = ProcessInfo.processInfo.hostName
            .replacingOccurrences(of: ".local", with: "")
            .components(separatedBy: ".").first ?? "Mac"
        let cleaned = raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0 == "-" ? Character($0) : "-" }
        return String(cleaned).isEmpty ? "Mac" : String(cleaned)
    }

    // MARK: Scheduling

    /// Fire-and-forget. Coalesces: many requests during a running cycle => exactly one more cycle.
    /// `commitNow` is the one-click "Commit & Sync" of manual mode; it is sticky until a cycle runs it.
    public func requestSync(commitNow: Bool = false) {
        lock.lock()
        if commitNow { wantCommit = true }
        if running { pending = true; lock.unlock(); return }
        running = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            while true {
                self.lock.lock()
                let commit = self.wantCommit
                self.wantCommit = false
                self.pending = false
                self.lock.unlock()

                let report = self.syncOnce(commitNow: commit)
                self.onReport?(report)

                self.lock.lock()
                if self.pending { self.lock.unlock(); continue }
                self.running = false
                self.lock.unlock()
                break
            }
        }
    }

    /// Recomputes LocalState only (no network, no writes). Used on every file change in manual mode.
    public func requestLocalRefresh() {
        queue.async { [weak self] in
            guard let self, let state = try? self.localState() else { return }
            self.onLocalState?(state)
        }
    }

    // MARK: The cycle

    /// One full cycle, synchronously. Never throws: failures become a status.
    /// `commitNow` makes Gitstick commit even in manual mode (respecting what you staged).
    @discardableResult
    public func syncOnce(commitNow: Bool = false) -> SyncReport {
        onStatus?(.syncing)
        var report = cycle(commitNow: commitNow)
        report.local = (try? localState()) ?? report.local
        onLocalState?(report.local)
        onStatus?(report.status)
        return report
    }

    private func cycle(commitNow: Bool) -> SyncReport {
        var report = SyncReport()
        let mode = self.mode
        if mode == .paused {
            report.status = .paused("Sync is off for this drive")
            return report
        }
        do {
            if let reason = humanActivity() {
                report.status = .paused(reason)
                return report
            }
            try gatekeeper.installExcludes(gitDir: git.gitDir)
            guard let branch = currentBranch() else {
                report.status = .paused("Not on a branch (detached HEAD)")
                return report
            }
            if mode == .auto {
                try snapshot(respectStaging: false, into: &report)
            } else if commitNow {
                try snapshot(respectStaging: true, into: &report)
            }
            report.status = try exchange(branch: branch, report: &report)
        } catch {
            // A failed merge must never leave the tree half-merged for the next cycle.
            abortIntegrationIfNeeded()
            report.status = Self.isOffline(error) ? .offline(lastSync: lastSync) : .error(Self.humanize(error))
        }
        if case .idle = report.status {
            lastSync = Date()
            report.status = .idle(lastSync: lastSync)
        }
        return report
    }

    /// Step 1 — commit local work (except what the gatekeeper holds back).
    ///
    /// `respectStaging`: if you staged something, commit exactly that; otherwise commit everything.
    /// That's how "Commit & Sync" behaves in manual mode — your staging is a decision, honor it.
    func snapshot(respectStaging: Bool, into report: inout SyncReport) throws {
        let hasStaged = !(try git.run(["diff", "--cached", "--quiet"], allowFailure: true).ok)
        if !(respectStaging && hasStaged) {
            try git.run(["add", "-A"])
        }
        var staged = parseNameStatusZ(try git.run(["diff", "--cached", "--name-status", "-z"]).stdoutData)

        // Hold back anything risky: unstage it, keep it on disk, report it.
        var held: [HeldFile] = []
        for change in staged where change.status != "D" {
            if let reason = gatekeeper.check(path: change.path, root: git.repo) {
                held.append(HeldFile(path: change.path, reason: reason))
            }
        }
        if !held.isEmpty {
            let paths = held.map(\.path)
            // Unstage (never delete) them. For a brand-new file this returns it to "untracked";
            // for a tracked file the last committed version stays in the index.
            if hasCommits() {
                try git.run(["reset", "-q", "--"] + paths)
            } else {
                try git.run(["rm", "-q", "--cached", "--"] + paths)
            }
            staged.removeAll { c in paths.contains(c.path) }
        }
        report.heldBack = held

        guard !staged.isEmpty else { return }
        let message = CommitMessage.make(from: staged)
        try git.run(["commit", "-q", "--no-verify", "-m", message])
        report.committed = message.components(separatedBy: "\n").first
    }

    /// Steps 2–4 — fetch, integrate, push. Retries if someone pushed in between.
    func exchange(branch: String, report: inout SyncReport) throws -> SyncStatus {
        guard hasRemote() else { return .idle(lastSync: nil) } // local-only drive: nothing to exchange

        for _ in 0..<maxPushAttempts {
            try git.run(["fetch", "-q", "--prune", remote])
            let remoteRef = "refs/remotes/\(remote)/\(branch)"
            let remoteExists = git.value(["rev-parse", "--verify", "-q", remoteRef]) != nil

            if remoteExists {
                if let review = try awaitingReview(remoteRef: remoteRef) { return .incoming(review) }
                if let wait = try integrate(remoteRef: remoteRef, report: &report) { return wait }
            }

            guard hasCommits() else { return .idle(lastSync: nil) }
            if remoteExists && !isAhead(of: remoteRef) { return .idle(lastSync: nil) }

            let push = try git.run(["push", "-q", remote, "HEAD:refs/heads/\(branch)"], allowFailure: true)
            if push.ok { report.pushed = true; return .idle(lastSync: nil) }

            switch Self.classifyPushFailure(push.stderr) {
            case .raced: continue                              // someone pushed first: fetch & merge again
            case .protected: return try divert(report: &report)
            case .other(let msg): throw SyncFailure(message: msg)
            }
        }
        throw SyncFailure(message: "Remote keeps changing; will retry shortly")
    }

    // MARK: Reviewing incoming changes

    /// With `pullPolicy == .review`: if GitHub is ahead and you haven't accepted exactly this remote
    /// state, describe it and stop. Returns nil when there's nothing to review (not behind, policy
    /// is automatic, or you accepted this very commit).
    func awaitingReview(remoteRef: String) throws -> IncomingChanges? {
        guard pullPolicy == .review, hasCommits(), let remoteHead = git.value(["rev-parse", remoteRef]) else { return nil }
        guard (Int(git.value(["rev-list", "--count", "HEAD..\(remoteRef)"]) ?? "0") ?? 0) > 0 else { return nil }
        if decision(.accepted) == remoteHead { return nil }
        return try describeIncoming(remoteRef: remoteRef, remoteHead: remoteHead, declined: decision(.declined) == remoteHead)
    }

    func describeIncoming(remoteRef: String, remoteHead: String, declined: Bool) throws -> IncomingChanges {
        let log = try git.run(["log", "--format=%h%x1f%an%x1f%s", "-z", "HEAD..\(remoteRef)"]).stdoutData
        let commits: [IncomingChanges.Commit] = log.split(separator: 0).compactMap { entry in
            let f = String(decoding: entry, as: UTF8.self).components(separatedBy: "\u{1f}")
            guard f.count == 3 else { return nil }
            return .init(sha: f[0], author: f[1], subject: f[2])
        }
        let base = git.value(["merge-base", "HEAD", remoteRef])
        let files = parseNameStatusZ(try git.run(["diff", "--name-status", "-z", base ?? "HEAD", remoteRef]).stdoutData)
        var alsoHere: [String] = []
        if let base {
            let ours = Set(parseNameStatusZ(try git.run(["diff", "--name-status", "-z", base, "HEAD"]).stdoutData).map(\.path))
            alsoHere = files.map(\.path).filter(ours.contains)
        }
        return IncomingChanges(remoteHead: remoteHead, commits: commits, files: files, alsoChangedHere: alsoHere, declined: declined)
    }

    /// "Yes, bring these in." Takes effect on the next cycle.
    public func acceptIncoming(_ changes: IncomingChanges) {
        record(.accepted, changes.remoteHead)
        record(.declined, nil)
    }

    /// "Not now." The changes stay on GitHub, the drive shows them as held off, and you're only
    /// asked again when GitHub moves on. Go to GitHub to sort out why.
    public func declineIncoming(_ changes: IncomingChanges) {
        record(.declined, changes.remoteHead)
    }

    /// Clears a decline so the next cycle asks again about the same changes.
    public func reconsiderIncoming() {
        record(.declined, nil)
    }

    public enum Decision: String, Sendable { case accepted, declined }

    /// Decisions live in .git/gitstick/ so they survive a relaunch and are visible to the CLI.
    private func decisionFile(_ d: Decision) -> URL {
        git.gitDir.appendingPathComponent("gitstick").appendingPathComponent(d.rawValue)
    }

    public func decision(_ d: Decision) -> String? {
        (try? String(contentsOf: decisionFile(d), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func record(_ d: Decision, _ sha: String?) {
        let file = decisionFile(d)
        if let sha {
            try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? sha.write(to: file, atomically: true, encoding: .utf8)
        } else {
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// Merge remote into local. Fast-forward when possible; otherwise merge commit with keep-both.
    /// Returns a `.waiting` status (having changed nothing) when merging now would touch work
    /// that isn't committed.
    func integrate(remoteRef: String, report: inout SyncReport) throws -> SyncStatus? {
        if !hasCommits() {
            // Unborn local branch (fresh clone of an empty repo, or first pull).
            // Only adopt the remote if nothing local would be overwritten.
            let r = try git.run(["checkout", "-q", "-B", currentBranch() ?? "main", remoteRef], allowFailure: true)
            if r.ok { report.pulled = true; return nil }
            if let w = waitingStatus(fromMergeError: r.stderr, behind: 1) { return w }
            throw SyncFailure(message: r.stderr)
        }
        let behind = Int(git.value(["rev-list", "--count", "HEAD..\(remoteRef)"]) ?? "0") ?? 0
        guard behind > 0 else { return nil }

        // Our conflict resolution commits the index. If YOU have staged something (manual mode),
        // that commit would swallow it. So: never merge over a non-empty index.
        if !(try git.run(["diff", "--cached", "--quiet"], allowFailure: true).ok) {
            return .waiting("\(Self.plural(behind, "change")) on GitHub — commit or unstage your staged files to pull")
        }

        var mergeArgs = ["merge", "-q", "--no-edit", "--no-verify"]
        // Two Macs that each made the first commit into an empty repo have no common ancestor.
        // That's still the same drive, so join the histories (add/add collisions become keep-both).
        if git.value(["merge-base", "HEAD", remoteRef]) == nil { mergeArgs.append("--allow-unrelated-histories") }
        let merge = try git.run(mergeArgs + [remoteRef], allowFailure: true)
        if merge.ok { report.pulled = true; return nil }

        // Git refused before touching anything (it would overwrite uncommitted/untracked files).
        if let w = waitingStatus(fromMergeError: merge.stderr + merge.stdout, behind: behind) { return w }

        let resolver = ConflictResolver(git: git, deviceName: deviceName)
        guard !(try resolver.conflictedPaths()).isEmpty else {
            throw SyncFailure(message: merge.stderr.isEmpty ? "Merge failed" : merge.stderr)
        }
        report.pulled = true
        let copies = try resolver.resolveAll()
        report.conflictCopies += copies
        let note = copies.isEmpty ? "" : "\n\nKept both versions of:\n" + copies.map { "  \($0)" }.joined(separator: "\n")
        try git.run(["commit", "-q", "--no-verify", "-m", "Merge remote changes\(note)\n\n[gitstick]"])
        return nil
    }

    /// Recognizes git's "your local changes would be overwritten" refusals, which leave the repo
    /// untouched, and turns them into a friendly waiting state naming the files in the way.
    func waitingStatus(fromMergeError text: String, behind: Int) -> SyncStatus? {
        guard text.contains("would be overwritten") else { return nil }
        let files = text.components(separatedBy: "\n")
            .filter { $0.hasPrefix("\t") }
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let which: String
        switch files.count {
        case 0: which = "files you've changed"
        case 1: which = files[0]
        default: which = "\(files[0]) and \(files.count - 1) more"
        }
        let action = mode == .auto ? "move or rename" : "commit"
        return .waiting("\(Self.plural(behind, "change")) on GitHub touch \(which) — \(action) to pull")
    }

    /// The branch refused us (protected / no write access). Put the work somewhere safe instead.
    func divert(report: inout SyncReport) throws -> SyncStatus {
        let side = "gitstick/\(deviceName.lowercased())"
        let push = try git.run(["push", "-q", remote, "HEAD:refs/heads/\(side)"], allowFailure: true)
        if push.ok {
            report.pushed = true
            return .divertedTo(branch: side)
        }
        throw SyncFailure(message: "Can't write to this drive (read-only). Your files are safe locally.")
    }

    // MARK: Guards & queries

    /// How long to give a transient `index.lock` (VS Code's background `git status`, a quick
    /// `git add` in the terminal) to go away before treating it as someone really working here.
    public var lockGracePeriod: TimeInterval = 2

    /// Detects a human (or another tool) mid-way through a git operation.
    public func humanActivity() -> String? {
        let fm = FileManager.default
        let lock = git.gitDir.appendingPathComponent("index.lock").path
        let deadline = Date().addingTimeInterval(lockGracePeriod)
        while fm.fileExists(atPath: lock) {
            if Date() >= deadline { return "Another git process is running" }
            Thread.sleep(forTimeInterval: 0.1)
        }
        let markers: [(String, String)] = [
            ("MERGE_HEAD", "A merge is in progress"),
            ("rebase-merge", "A rebase is in progress"),
            ("rebase-apply", "A rebase is in progress"),
            ("CHERRY_PICK_HEAD", "A cherry-pick is in progress"),
            ("REVERT_HEAD", "A revert is in progress"),
            ("BISECT_LOG", "A bisect is in progress"),
        ]
        for (file, reason) in markers where fm.fileExists(atPath: git.gitDir.appendingPathComponent(file).path) {
            return reason
        }
        return nil
    }

    /// Working-tree / index / ahead-behind counts. Read-only (uses --no-optional-locks so it
    /// never contends with VS Code or the terminal for index.lock).
    public func localState() throws -> LocalState {
        var s = LocalState()
        let status = try git.run(["--no-optional-locks", "status", "--porcelain=v1", "-z", "--untracked-files=all"])
        let entries = status.stdoutData.split(separator: 0)
        var skipNext = false
        for e in entries {
            if skipNext { skipNext = false; continue }
            guard e.count >= 3 else { continue }
            let x = Character(UnicodeScalar(e[e.startIndex]))
            s.uncommitted += 1
            if x != " " && x != "?" { s.staged += 1 }
            if x == "R" || x == "C" { skipNext = true } // rename source path follows
        }
        if let branch = currentBranch(), git.value(["rev-parse", "--verify", "-q", "refs/remotes/\(remote)/\(branch)"]) != nil {
            let counts = git.value(["rev-list", "--left-right", "--count", "HEAD...refs/remotes/\(remote)/\(branch)"])?
                .split(whereSeparator: { $0 == "\t" || $0 == " " }).compactMap { Int($0) } ?? []
            if counts.count == 2 { s.ahead = counts[0]; s.behind = counts[1] }
        }
        return s
    }

    func abortIntegrationIfNeeded() {
        if FileManager.default.fileExists(atPath: git.gitDir.appendingPathComponent("MERGE_HEAD").path) {
            try? git.run(["merge", "--abort"], allowFailure: true)
        }
    }

    func currentBranch() -> String? { git.value(["symbolic-ref", "--short", "-q", "HEAD"]) }
    func hasCommits() -> Bool { git.value(["rev-parse", "--verify", "-q", "HEAD"]) != nil }
    func hasRemote() -> Bool { git.value(["remote"])?.split(separator: "\n").contains { $0 == remote } ?? false }
    func isAhead(of ref: String) -> Bool {
        (Int(git.value(["rev-list", "--count", "\(ref)..HEAD"]) ?? "0") ?? 0) > 0
    }

    static func plural(_ n: Int, _ word: String) -> String { n == 1 ? "1 \(word)" : "\(n) \(word)s" }

    // MARK: Errors

    enum PushFailure: Equatable { case raced, protected, other(String) }

    static func classifyPushFailure(_ stderr: String) -> PushFailure {
        let s = stderr.lowercased()
        if s.contains("non-fast-forward") || s.contains("fetch first") || s.contains("cannot lock ref") {
            return .raced
        }
        if s.contains("protected branch") || s.contains("gh006") || s.contains("gh013")
            || s.contains("permission to") || s.contains("403") {
            return .protected
        }
        return .other(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// A network failure, as opposed to something wrong with the repo or the account: no DNS, no
    /// route, a refused or timed-out connection, or a transfer that stalled (see `Git.stallSeconds`).
    static func isOffline(_ error: Error) -> Bool {
        let text = "\(error)".lowercased()
        return ["could not resolve host", "unable to access", "could not connect", "connection refused",
                "connection timed out", "network is unreachable", "operation timed out", "operation too slow",
                "could not read from remote repository", "connection reset", "ssl_connect", "no route to host"]
            .contains { text.contains($0) }
    }

    static func humanize(_ error: Error) -> String {
        let text = "\(error)".lowercased()
        if text.contains("authentication") || text.contains("could not read username") {
            return "Not signed in to GitHub"
        }
        if text.contains("author identity unknown") || text.contains("please tell me who you are")
            || text.contains("unable to auto-detect email") || text.contains("empty ident name") {
            return "Can't commit yet: no name and email for git. Sign in to GitHub (or set user.name and user.email) and this will retry"
        }
        return "\(error)"
    }
}

public struct SyncFailure: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
