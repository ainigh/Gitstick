import Foundation

/// Resolves merge conflicts without asking, by never choosing a loser.
///
/// Policy ("keep both"):
///  - both sides edited a file  -> the remote version keeps the original name (so collaborators
///    see no surprise), the local version is saved next to it as
///    "name (conflict from <Mac> <date>).ext". Both are committed.
///  - one side edited, the other deleted -> the edited version wins (an edit is newer intent
///    than a delete, and a delete is recoverable from history anyway).
///  - both deleted -> deleted.
///
/// Invariant: after resolve(), no byte that existed on either side is lost.
public struct ConflictResolver {
    public let git: Git
    public let deviceName: String
    public var now: () -> Date = Date.init

    public init(git: Git, deviceName: String) {
        self.git = git
        self.deviceName = deviceName
    }

    /// Paths with unmerged entries in the index.
    public func conflictedPaths() throws -> [String] {
        let r = try git.run(["diff", "--name-only", "--diff-filter=U", "-z"])
        return r.stdoutData.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Resolves every conflict in the index. Returns the conflict-copy paths that were created.
    @discardableResult
    public func resolveAll() throws -> [String] {
        var copies: [String] = []
        for path in try conflictedPaths() {
            if let copy = try resolve(path: path) { copies.append(copy) }
        }
        return copies
    }

    private func stages(of path: String) throws -> Set<Int> {
        let r = try git.run(["ls-files", "-u", "-z", "--", path])
        var set = Set<Int>()
        for entry in r.stdoutData.split(separator: 0) {
            // "<mode> <sha> <stage>\t<path>"
            let line = String(decoding: entry, as: UTF8.self)
            let meta = line.split(separator: "\t", maxSplits: 1).first ?? ""
            if let s = meta.split(separator: " ").last, let n = Int(s) { set.insert(n) }
        }
        return set
    }

    private func resolve(path: String) throws -> String? {
        let st = try stages(of: path)
        let ours = st.contains(2), theirs = st.contains(3)
        let fileURL = git.repo.appendingPathComponent(path)

        switch (ours, theirs) {
        case (true, true):
            let local = try git.run(["show", ":2:\(path)"]).stdoutData
            try git.run(["checkout", "--theirs", "--", path])
            let copy = conflictCopyName(for: path)
            let copyURL = git.repo.appendingPathComponent(copy)
            try FileManager.default.createDirectory(at: copyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try local.write(to: copyURL)
            // Preserve the executable bit of our version, if any.
            if let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
               let perms = attrs[.posixPermissions] {
                try? FileManager.default.setAttributes([.posixPermissions: perms], ofItemAtPath: copyURL.path)
            }
            try git.run(["add", "--", path, copy])
            return copy
        case (true, false):
            try git.run(["checkout", "--ours", "--", path])
            try git.run(["add", "--", path])
        case (false, true):
            try git.run(["checkout", "--theirs", "--", path])
            try git.run(["add", "--", path])
        case (false, false):
            try git.run(["rm", "-q", "--cached", "--ignore-unmatch", "--", path])
            try? FileManager.default.removeItem(at: fileURL)
        }
        return nil
    }

    func conflictCopyName(for path: String) -> String {
        let dir = (path as NSString).deletingLastPathComponent
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension
        let base = ext.isEmpty ? file : (file as NSString).deletingPathExtension

        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = f.string(from: now())

        var candidate = ""
        var n = 1
        repeat {
            let suffix = n == 1 ? "" : " \(n)"
            let name = "\(base) (conflict from \(deviceName) \(stamp)\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
            candidate = dir.isEmpty ? name : (dir as NSString).appendingPathComponent(name)
            n += 1
        } while FileManager.default.fileExists(atPath: git.repo.appendingPathComponent(candidate).path)
        return candidate
    }
}
