import Foundation

public enum SyncStatus: Equatable {
    case idle(lastSync: Date?)
    case syncing
    /// Someone (the user, VS Code, a terminal) is mid-operation in this repo. We wait.
    case paused(String)
    /// Branch is protected / read-only: local work is safe on a side branch.
    case divertedTo(branch: String)
    case error(String)
}

public struct SyncReport: Equatable {
    public var committed: String? = nil          // subject of the auto-commit, if any
    public var pulled = false                     // remote changes were integrated
    public var pushed = false
    public var conflictCopies: [String] = []
    public var heldBack: [HeldFile] = []
    public var status: SyncStatus = .idle(lastSync: nil)
}

/// One plugged-in drive's sync engine.
///
/// The cycle is always the same, and always in this order:
///
///     guard  ->  snapshot (commit local)  ->  fetch  ->  integrate (merge, keep-both)  ->  push
///
/// Invariants (see ARCHITECTURE.md):
///  1. Local work is committed BEFORE anything remote touches the working tree.
///  2. Nothing ever prompts. Every decision has a default.
///  3. Never rewrite published history: no force-push, no rebase of pushed commits.
///  4. If a human is operating git in this repo, back off.
///  5. Cycles are serialized per repo; requests during a cycle coalesce into one follow-up.
public final class RepoSyncer: @unchecked Sendable {
    public let git: Git
    public var gatekeeper = Gatekeeper()
    public let deviceName: String
    public var remote = "origin"
    public var maxPushAttempts = 3

    public var onStatus: ((SyncStatus) -> Void)?
    public var onReport: ((SyncReport) -> Void)?

    private let queue: DispatchQueue
    private var running = false
    private var pending = false
    private let lock = NSLock()
    public private(set) var lastSync: Date?

    public init(git: Git, deviceName: String = RepoSyncer.defaultDeviceName) {
        self.git = git
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
    public func requestSync() {
        lock.lock()
        if running { pending = true; lock.unlock(); return }
        running = true
        lock.unlock()

        queue.async { [weak self] in
            guard let self else { return }
            while true {
                let report = self.syncOnce()
                self.onReport?(report)
                self.lock.lock()
                if self.pending { self.pending = false; self.lock.unlock(); continue }
                self.running = false
                self.lock.unlock()
                break
            }
        }
    }

    // MARK: The cycle

    /// One full cycle, synchronously. Never throws: failures become a status.
    @discardableResult
    public func syncOnce() -> SyncReport {
        var report = SyncReport()
        onStatus?(.syncing)
        do {
            if let reason = humanActivity() {
                report.status = .paused(reason)
            } else {
                try gatekeeper.installExcludes(gitDir: git.gitDir)
                guard let branch = currentBranch() else {
                    report.status = .paused("Not on a branch (detached HEAD)")
                    onStatus?(report.status)
                    return report
                }
                try snapshot(into: &report)
                report.status = try exchange(branch: branch, report: &report)
            }
        } catch {
            // A failed merge must never leave the tree half-merged for the next cycle.
            abortIntegrationIfNeeded()
            report.status = .error(Self.humanize(error))
        }
        if case .idle = report.status {
            lastSync = Date()
            report.status = .idle(lastSync: lastSync)
        }
        onStatus?(report.status)
        return report
    }

    /// Step 1 — commit everything local (except what the gatekeeper holds back).
    func snapshot(into report: inout SyncReport) throws {
        try git.run(["add", "-A"])
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
                try integrate(remoteRef: remoteRef, report: &report)
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

    /// Merge remote into local. Fast-forward when possible; otherwise merge commit with keep-both.
    func integrate(remoteRef: String, report: inout SyncReport) throws {
        if !hasCommits() {
            // Fresh clone of a repo whose local branch is unborn: adopt remote as-is.
            try git.run(["reset", "-q", "--hard", remoteRef])
            report.pulled = true
            return
        }
        let behind = Int(git.value(["rev-list", "--count", "HEAD..\(remoteRef)"]) ?? "0") ?? 0
        guard behind > 0 else { return }

        var mergeArgs = ["merge", "-q", "--no-edit", "--no-verify"]
        // Two Macs that each made the first commit into an empty repo have no common ancestor.
        // That's still the same drive, so join the histories (add/add collisions become keep-both).
        if git.value(["merge-base", "HEAD", remoteRef]) == nil { mergeArgs.append("--allow-unrelated-histories") }
        let merge = try git.run(mergeArgs + [remoteRef], allowFailure: true)
        report.pulled = true
        if merge.ok { return }

        let resolver = ConflictResolver(git: git, deviceName: deviceName)
        guard !(try resolver.conflictedPaths()).isEmpty else {
            throw SyncFailure(message: merge.stderr.isEmpty ? "Merge failed" : merge.stderr)
        }
        let copies = try resolver.resolveAll()
        report.conflictCopies += copies
        let note = copies.isEmpty ? "" : "\n\nKept both versions of:\n" + copies.map { "  \($0)" }.joined(separator: "\n")
        try git.run(["commit", "-q", "--no-verify", "-m", "Merge remote changes\(note)\n\n[gitstick]"])
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

    /// Detects a human (or another tool) mid-way through a git operation.
    public func humanActivity() -> String? {
        let fm = FileManager.default
        let markers: [(String, String)] = [
            ("index.lock", "Another git process is running"),
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

    static func humanize(_ error: Error) -> String {
        let text = "\(error)".lowercased()
        if text.contains("could not resolve host") || text.contains("unable to access") {
            return "Offline — changes are saved locally and will sync later"
        }
        if text.contains("authentication") || text.contains("could not read username") {
            return "Not signed in to GitHub"
        }
        return "\(error)"
    }
}

public struct SyncFailure: Error, CustomStringConvertible {
    public let message: String
    public var description: String { message }
}
