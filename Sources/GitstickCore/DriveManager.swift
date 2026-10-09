import Foundation

/// A drive that is plugged in: a real folder on disk, kept in sync with a GitHub repo.
public struct PluggedDrive: Codable, Identifiable, Hashable, Sendable {
    public var id: String { fullName }
    public let fullName: String
    public let owner: String
    public let name: String
    public let cloneURL: String
    public let localPath: String
    public var mode: SyncMode
    public var pullPolicy: PullPolicy

    public var url: URL { URL(fileURLWithPath: localPath) }

    public init(fullName: String, owner: String, name: String, cloneURL: String, localPath: String, mode: SyncMode,
                pullPolicy: PullPolicy = .automatic) {
        self.fullName = fullName; self.owner = owner; self.name = name
        self.cloneURL = cloneURL; self.localPath = localPath; self.mode = mode; self.pullPolicy = pullPolicy
    }

    enum CodingKeys: String, CodingKey { case fullName, owner, name, cloneURL, localPath, mode, autoSync, pullPolicy }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        fullName = try c.decode(String.self, forKey: .fullName)
        owner = try c.decode(String.self, forKey: .owner)
        name = try c.decode(String.self, forKey: .name)
        cloneURL = try c.decode(String.self, forKey: .cloneURL)
        localPath = try c.decode(String.self, forKey: .localPath)
        pullPolicy = try c.decodeIfPresent(PullPolicy.self, forKey: .pullPolicy) ?? .automatic
        if let m = try c.decodeIfPresent(SyncMode.self, forKey: .mode) {
            mode = m
        } else {
            // v0.1 stored `autoSync: Bool` (false meant read-only).
            mode = (try c.decodeIfPresent(Bool.self, forKey: .autoSync) ?? true) ? .auto : .manual
        }
    }

    public func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(fullName, forKey: .fullName); try c.encode(owner, forKey: .owner)
        try c.encode(name, forKey: .name); try c.encode(cloneURL, forKey: .cloneURL)
        try c.encode(localPath, forKey: .localPath); try c.encode(mode, forKey: .mode)
        try c.encode(pullPolicy, forKey: .pullPolicy)
    }
}

/// Wires one drive's watcher -> debouncers -> syncer, plus a periodic pull.
///
///                 file edited                 HEAD moved (a commit)      every 60s
///   auto     ->   sync (3s quiet)             sync (3s quiet)            sync
///   manual   ->   refresh local counts only   sync (1s quiet)            sync (pull-if-safe + push)
///   paused   ->   refresh local counts only   refresh local counts       —
///
/// In manual mode a file edit never causes network traffic or a write; only your commits do.
public final class DriveSession {
    public let drive: PluggedDrive
    public let syncer: RepoSyncer
    private let watcher: FolderWatcher
    private var syncSoon: Debouncer!
    private var syncPromptly: Debouncer!
    private var refreshLocal: Debouncer!
    private var timer: DispatchSourceTimer?
    public var pollInterval: TimeInterval = 60

    init(drive: PluggedDrive, git: Git) {
        self.drive = drive
        self.syncer = RepoSyncer(git: git, mode: drive.mode)
        self.syncer.pullPolicy = drive.pullPolicy
        self.watcher = makeWatcher(for: drive.url)
        self.syncSoon = Debouncer(quiet: 3, maxWait: 30) { [weak self] in self?.syncer.requestSync() }
        self.syncPromptly = Debouncer(quiet: 1, maxWait: 5) { [weak self] in self?.syncer.requestSync() }
        self.refreshLocal = Debouncer(quiet: 0.5, maxWait: 3) { [weak self] in self?.syncer.requestLocalRefresh() }
    }

    func start() {
        let mode = drive.mode
        watcher.start { [weak self] kind in
            guard let self else { return }
            switch (mode, kind) {
            case (.auto, _): self.syncSoon.poke()
            case (.manual, .head): self.syncPromptly.poke()
            case (.manual, .workingTree), (.paused, _): self.refreshLocal.poke()
            }
        }
        if mode != .paused {
            let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .seconds(10))
            t.setEventHandler { [weak self] in self?.syncer.requestSync() }
            t.resume()
            timer = t
            syncer.requestSync() // catch up on anything that happened while we weren't running
        } else {
            syncer.requestSync() // reports "paused" + local counts, touches nothing
        }
    }

    func stop() {
        watcher.stop()
        syncSoon.cancel(); syncPromptly.cancel(); refreshLocal.cancel()
        timer?.cancel()
        timer = nil
    }

    public func syncNow() { syncer.requestSync() }

    /// Manual mode's one-click commit: commits what you staged, or everything if nothing is staged
    /// (minus anything the Gatekeeper holds back), then syncs.
    public func commitAndSync() { syncer.requestSync(commitNow: true) }
}

public enum DriveError: Error, CustomStringConvertible {
    case folderOccupied(String), cloneFailed(String)
    public var description: String {
        switch self {
        case .folderOccupied(let p): return "\(p) already exists and isn't this repo"
        case .cloneFailed(let m): return "Couldn't plug in: \(m)"
        }
    }
}

/// Owns the set of plugged-in drives.
///
/// Layout on disk:  <root>/<PC>/<drive>      e.g. ~/Gitstick/acme/website
/// State:           ~/Library/Application Support/Gitstick/drives.json
public final class DriveManager: @unchecked Sendable {
    public let root: URL
    public let tokens: TokenProvider
    public var identity: (name: String, email: String)?
    public private(set) var drives: [PluggedDrive] = []
    public private(set) var sessions: [String: DriveSession] = [:]

    public var onStatus: ((String, SyncStatus) -> Void)?
    public var onReport: ((String, SyncReport) -> Void)?
    public var onLocalState: ((String, LocalState) -> Void)?

    private let storeURL: URL
    private let lock = NSLock()

    public init(root: URL? = nil, stateDir: URL? = nil, tokens: TokenProvider) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        self.root = root ?? home.appendingPathComponent("Gitstick")
        let state = stateDir ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first!.appendingPathComponent("Gitstick")
        try? FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        self.storeURL = state.appendingPathComponent("drives.json")
        self.tokens = tokens
        load()
    }

    // MARK: Persistence

    func load() {
        guard let data = try? Data(contentsOf: storeURL),
              let list = try? JSONDecoder().decode([PluggedDrive].self, from: data) else { return }
        drives = list
    }

    func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(drives) { try? data.write(to: storeURL, options: .atomic) }
    }

    // MARK: Lifecycle

    /// Starts syncing every plugged drive whose folder still exists.
    public func startAll() {
        for d in drives where FileManager.default.fileExists(atPath: d.localPath) { startSession(d) }
    }

    public func stopAll() { sessions.values.forEach { $0.stop() } }

    public func isPlugged(_ fullName: String) -> Bool { drives.contains { $0.fullName == fullName } }

    /// "Plug in": partial clone (file contents download lazily from GitHub on checkout of other
    /// revisions; the current tree is materialized so every app can open files normally).
    @discardableResult
    public func plugIn(_ remote: RemoteDrive) throws -> PluggedDrive {
        let folder = root.appendingPathComponent(remote.owner).appendingPathComponent(remote.name)
        let fm = FileManager.default
        try fm.createDirectory(at: folder.deletingLastPathComponent(), withIntermediateDirectories: true)

        if fm.fileExists(atPath: folder.path) {
            let existing = Git(repo: folder).value(["remote", "get-url", "origin"]) ?? ""
            guard Self.sameRepo(existing, remote.cloneURL) else { throw DriveError.folderOccupied(folder.path) }
        } else {
            let parent = Git(repo: folder.deletingLastPathComponent(), credentials: tokens)
            let r = try parent.run(["clone", "-q", "--filter=blob:none", remote.cloneURL, folder.lastPathComponent],
                                   allowFailure: true)
            guard r.ok else { throw DriveError.cloneFailed(r.stderr.trimmingCharacters(in: .whitespacesAndNewlines)) }
        }

        let drive = PluggedDrive(fullName: remote.fullName, owner: remote.owner, name: remote.name,
                                 cloneURL: remote.cloneURL, localPath: folder.path,
                                 mode: remote.canWrite && !remote.archived ? .auto : .manual)
        lock.lock()
        drives.removeAll { $0.fullName == drive.fullName }
        drives.append(drive)
        save()
        lock.unlock()
        startSession(drive)
        return drive
    }

    /// "Eject": one last synchronous sync so nothing is left behind, then stop watching.
    /// The folder stays on disk unless `removeLocalCopy` and the final sync succeeded.
    @discardableResult
    public func eject(_ fullName: String, removeLocalCopy: Bool = false) -> SyncReport? {
        guard let session = sessions[fullName] else {
            lock.lock(); drives.removeAll { $0.fullName == fullName }; save(); lock.unlock()
            return nil
        }
        session.stop()
        let final = session.syncer.syncOnce()
        sessions[fullName] = nil
        lock.lock()
        drives.removeAll { $0.fullName == fullName }
        save()
        lock.unlock()

        // Only ever delete a folder whose every byte is on GitHub. In manual mode, eject pushes your
        // commits but never commits for you, so uncommitted work keeps the folder alive.
        let clean: Bool = {
            guard case .idle = final.status, final.heldBack.isEmpty else { return false }
            return final.local.uncommitted == 0 && final.local.ahead == 0
        }()
        if removeLocalCopy && clean { try? FileManager.default.removeItem(at: session.drive.url) }
        return final
    }

    public func syncNow(_ fullName: String) { sessions[fullName]?.syncNow() }
    public func commitAndSync(_ fullName: String) { sessions[fullName]?.commitAndSync() }

    // MARK: Reviewing incoming changes

    public func acceptIncoming(_ changes: IncomingChanges, for fullName: String) {
        sessions[fullName]?.syncer.acceptIncoming(changes); sessions[fullName]?.syncNow()
    }
    public func declineIncoming(_ changes: IncomingChanges, for fullName: String) {
        sessions[fullName]?.syncer.declineIncoming(changes); sessions[fullName]?.syncNow()
    }
    public func reconsiderIncoming(_ fullName: String) {
        sessions[fullName]?.syncer.reconsiderIncoming(); sessions[fullName]?.syncNow()
    }

    /// Switches whether GitHub's changes land on their own or wait for your OK. Persisted; takes
    /// effect on the next cycle (switching back to automatic also brings in anything held off).
    public func setPullPolicy(_ policy: PullPolicy, for fullName: String) {
        lock.lock()
        guard let i = drives.firstIndex(where: { $0.fullName == fullName }) else { lock.unlock(); return }
        drives[i].pullPolicy = policy
        save()
        lock.unlock()
        if let s = sessions[fullName] {
            s.syncer.pullPolicy = policy
            if policy == .automatic { s.syncer.reconsiderIncoming() }
            s.syncNow()
        }
    }

    /// Switches a drive's mode. Takes effect immediately; persisted.
    public func setMode(_ mode: SyncMode, for fullName: String) {
        lock.lock()
        guard let i = drives.firstIndex(where: { $0.fullName == fullName }) else { lock.unlock(); return }
        drives[i].mode = mode
        let drive = drives[i]
        save()
        lock.unlock()
        if FileManager.default.fileExists(atPath: drive.localPath) { startSession(drive) }
    }

    private func startSession(_ drive: PluggedDrive) {
        sessions[drive.fullName]?.stop()
        // Only inject an identity if the user hasn't configured one for git themselves.
        let hasOwnIdentity = Git(repo: drive.url).value(["config", "user.email"]) != nil
        let git = Git(repo: drive.url, credentials: tokens, identity: hasOwnIdentity ? nil : identity)
        let session = DriveSession(drive: drive, git: git)
        let id = drive.fullName
        session.syncer.onStatus = { [weak self] s in self?.onStatus?(id, s) }
        session.syncer.onReport = { [weak self] r in self?.onReport?(id, r) }
        session.syncer.onLocalState = { [weak self] l in self?.onLocalState?(id, l) }
        sessions[id] = session
        session.start()
    }

    static func sameRepo(_ a: String, _ b: String) -> Bool {
        func norm(_ s: String) -> String {
            var s = s.lowercased()
            if s.hasSuffix(".git") { s.removeLast(4) }
            s = s.replacingOccurrences(of: "git@github.com:", with: "github.com/")
            s = s.replacingOccurrences(of: "https://", with: "")
            return s
        }
        return norm(a) == norm(b)
    }
}
