import Foundation

/// Result of a single git invocation.
public struct GitResult {
    public let status: Int32
    public let stdoutData: Data
    public let stderr: String
    public var stdout: String { String(decoding: stdoutData, as: UTF8.self) }
    public var ok: Bool { status == 0 }
}

public struct GitError: Error, CustomStringConvertible {
    public let args: [String]
    public let result: GitResult
    public var description: String {
        "git \(args.joined(separator: " ")) failed (\(result.status)): \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}

/// Supplies credentials to git without ever prompting.
public protocol CredentialSource: Sendable {
    func token() -> String?
}

/// Thin, non-interactive wrapper around the `git` CLI.
///
/// Invariant: git must NEVER block waiting for a human. Every invocation disables
/// terminal prompts, editors and pagers, so a missing credential or a merge message
/// turns into an error/auto-message instead of a hang.
public struct Git: Sendable {
    public typealias Identity = (name: String, email: String)

    public let repo: URL
    public let credentials: CredentialSource?
    /// A fixed commit identity, passed as `-c user.name/user.email` on every call.
    public let identity: Identity?
    /// Looked up on every call instead, when the identity can become known (or change) after this
    /// `Git` was created: the GitHub sign-in finishing a few seconds after launch, for instance.
    /// `identity` wins when both are set.
    public let identityProvider: (@Sendable () -> Identity?)?

    public init(repo: URL, credentials: CredentialSource? = nil, identity: Identity? = nil,
                identityProvider: (@Sendable () -> Identity?)? = nil) {
        self.repo = repo
        self.credentials = credentials
        self.identity = identity
        self.identityProvider = identityProvider
    }

    /// Path of the git binary. Overridable for tests / unusual installs.
    public static var executable: String = {
        // Prefer a real git over the /usr/bin/git shim (which can pop an Xcode CLT install dialog).
        for path in ["/opt/homebrew/bin/git", "/usr/local/bin/git", "/usr/bin/git"]
        where FileManager.default.isExecutableFile(atPath: path) { return path }
        return "/usr/bin/git"
    }()

    /// A transfer slower than this, for `stallSeconds`, is treated as a dead connection and aborted
    /// (git's `http.lowSpeedLimit` / `http.lowSpeedTime`). Git itself would wait on a half-open
    /// socket forever, which would freeze the drive's serial queue; aborting turns a stalled fetch
    /// or push into an *offline* cycle that is retried a minute later.
    public static var stallBytesPerSecond = 1000
    public static var stallSeconds = 90

    @discardableResult
    public func run(_ args: [String], allowFailure: Bool = false, cwd: URL? = nil) throws -> GitResult {
        var full: [String] = ["-c", "core.quotepath=off", "-c", "core.pager=cat", "-c", "advice.detachedHead=false",
                              "-c", "http.lowSpeedLimit=\(Git.stallBytesPerSecond)", "-c", "http.lowSpeedTime=\(Git.stallSeconds)"]
        if let id = identity ?? identityProvider?() {
            full += ["-c", "user.name=\(id.name)", "-c", "user.email=\(id.email)"]
        }
        full += args

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Git.executable)
        process.arguments = full
        process.currentDirectoryURL = cwd ?? repo

        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_EDITOR"] = "true"
        env["GIT_MERGE_AUTOEDIT"] = "no"
        env["GIT_ASKPASS"] = "echo"
        env["SSH_ASKPASS"] = "echo"
        env["GCM_INTERACTIVE"] = "never"
        // An SSH remote must not stop at a host-key or passphrase question either: BatchMode makes
        // ssh fail instead of asking. The user's own GIT_SSH_COMMAND / GIT_SSH is left alone.
        if env["GIT_SSH_COMMAND"] == nil && env["GIT_SSH"] == nil {
            env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        }
        env["LC_ALL"] = "C"
        if let token = credentials?.token() {
            // Basic auth header with the token, passed as a one-shot config entry through the
            // environment (GIT_CONFIG_COUNT, git 2.31+). Nothing lands in .git/config or a URL, and
            // unlike a `-c` flag it isn't visible to every other process in `ps`.
            let basic = Data("x-access-token:\(token)".utf8).base64EncodedString()
            let n = Int(env["GIT_CONFIG_COUNT"] ?? "") ?? 0
            env["GIT_CONFIG_KEY_\(n)"] = "http.https://github.com/.extraheader"
            env["GIT_CONFIG_VALUE_\(n)"] = "AUTHORIZATION: basic \(basic)"
            env["GIT_CONFIG_COUNT"] = String(n + 1)
        }
        process.environment = env

        // Temp files instead of pipes: no deadlock on large outputs (e.g. `git show` of a big blob).
        let tmp = FileManager.default.temporaryDirectory
        let outURL = tmp.appendingPathComponent("gitstick-\(UUID().uuidString).out")
        let errURL = tmp.appendingPathComponent("gitstick-\(UUID().uuidString).err")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: outURL)
            try? FileManager.default.removeItem(at: errURL)
        }
        let outHandle = try FileHandle(forWritingTo: outURL)
        let errHandle = try FileHandle(forWritingTo: errURL)
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()

        let result = GitResult(
            status: process.terminationStatus,
            stdoutData: (try? Data(contentsOf: outURL)) ?? Data(),
            stderr: String(decoding: (try? Data(contentsOf: errURL)) ?? Data(), as: UTF8.self)
        )
        if !result.ok && !allowFailure { throw GitError(args: args, result: result) }
        return result
    }

    /// Convenience: trimmed stdout, or nil on failure.
    public func value(_ args: [String]) -> String? {
        guard let r = try? run(args, allowFailure: true), r.ok else { return nil }
        let s = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? nil : s
    }

    public var gitDir: URL { repo.appendingPathComponent(".git") }
}

/// Parses NUL-separated `--name-status -z` output into (status, path) pairs.
/// Renames/copies (R/C) carry two paths; we report the destination.
func parseNameStatusZ(_ data: Data) -> [(status: Character, path: String)] {
    let fields = data.split(separator: 0, omittingEmptySubsequences: true).map { String(decoding: $0, as: UTF8.self) }
    var out: [(Character, String)] = []
    var i = 0
    while i < fields.count {
        let code = fields[i]
        guard let s = code.first else { i += 1; continue }
        if s == "R" || s == "C" {
            if i + 2 < fields.count { out.append((s, fields[i + 2])) }
            i += 3
        } else {
            if i + 1 < fields.count { out.append((s, fields[i + 1])) }
            i += 2
        }
    }
    return out
}
