import Foundation

/// A drive that is plugged in: a real folder on disk, kept in sync with a GitHub repo.
public struct PluggedDrive: Codable, Identifiable, Hashable, Sendable {
    public var id: String { fullName }
    public let fullName: String
    public let owner: String
    public let name: String
    public let cloneURL: String
    public let localPath: String
    public var autoSync: Bool = true

    public var url: URL { URL(fileURLWithPath: localPath) }
}

/// Wires one drive's watcher -> debouncer -> syncer, plus a periodic pull.
public final class DriveSession {
    public let drive: PluggedDrive
    public let syncer: RepoSyncer
    private let watcher: FolderWatcher
    private var debouncer: Debouncer!
    private var timer: DispatchSourceTimer?
    public var pollInterval: TimeInterval = 60

    init(drive: PluggedDrive, git: Git) {
        self.drive = drive
        self.syncer = RepoSyncer(git: git)
        self.watcher = makeWatcher(for: drive.url)
        self.debouncer = Debouncer { [weak self] in self?.syncer.requestSync() }
    }

    func start() {
        guard drive.autoSync else { return }
        watcher.start { [weak self] in self?.debouncer.poke() }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        t.schedule(deadline: .now() + pollInterval, repeating: pollInterval, leeway: .seconds(10))
        t.setEventHandler { [weak self] in self?.syncer.requestSync() }
        t.resume()
        timer = t
        syncer.requestSync() // catch up on anything that happened while we weren't running
    }

    func stop() {
        watcher.stop()
        debouncer.cancel()
        timer?.cancel()
        timer = nil
    }

    public func syncNow() { syncer.requestSync() }
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
                                 cloneURL: remote.cloneURL, localPath: folder.path, autoSync: remote.canWrite)
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

        let clean: Bool = {
            if case .idle = final.status, final.heldBack.isEmpty { return true }
            return false
        }()
        if removeLocalCopy && clean { try? FileManager.default.removeItem(at: session.drive.url) }
        return final
    }

    public func syncNow(_ fullName: String) { sessions[fullName]?.syncNow() }

    private func startSession(_ drive: PluggedDrive) {
        sessions[drive.fullName]?.stop()
        // Only inject an identity if the user hasn't configured one for git themselves.
        let hasOwnIdentity = Git(repo: drive.url).value(["config", "user.email"]) != nil
        let git = Git(repo: drive.url, credentials: tokens, identity: hasOwnIdentity ? nil : identity)
        let session = DriveSession(drive: drive, git: git)
        let id = drive.fullName
        session.syncer.onStatus = { [weak self] s in self?.onStatus?(id, s) }
        session.syncer.onReport = { [weak self] r in self?.onReport?(id, r) }
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
