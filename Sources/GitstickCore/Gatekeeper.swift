import Foundation

/// Why a file was held back from an auto-commit.
public enum HoldReason: Equatable, Sendable, CustomStringConvertible {
    case looksLikeSecret(String)
    case tooLarge(bytes: Int64)
    /// The folder is a git repository of its own. Git would commit it as an empty pointer
    /// (a "gitlink"), so every other Mac would see an empty folder.
    case nestedRepository

    public var description: String {
        switch self {
        case .looksLikeSecret(let why): return "looks like a secret (\(why))"
        case .tooLarge(let b): return "too large (\(ByteCountFormatter.string(fromByteCount: b, countStyle: .file)))"
        case .nestedRepository: return "is a git repository of its own (delete its .git folder to sync its files)"
        }
    }
}

public struct HeldFile: Equatable, Sendable {
    public let path: String
    public let reason: HoldReason
}

/// Decides what may be committed without asking.
///
/// Invariant: the cost of a wrong auto-commit is permanent (history is public and forever),
/// the cost of holding a file back is a yellow badge. So when in doubt, hold back.
public struct Gatekeeper {
    public var maxFileBytes: Int64 = 50 * 1024 * 1024 // GitHub warns at 50MB, rejects at 100MB.
    public var scanContentBytes: Int = 1 * 1024 * 1024

    /// Junk that should never reach the remote. Written to .git/info/exclude (local only,
    /// so we never edit the repo's own .gitignore behind the user's back).
    public static let defaultExcludes: [String] = [
        ".DS_Store", "._*", ".Spotlight-V100", ".Trashes", "Icon\r",
        "*.swp", "*.swo", "*~", ".#*", "*.tmp", "*.crdownload", "*.part", "*.download",
        "~$*",                       // Office lock files
        ".~lock.*#",                 // LibreOffice lock files
        "node_modules/", ".venv/", "__pycache__/",
    ]

    static let secretNames: [String] = [
        ".env", ".envrc", ".npmrc", ".pypirc", ".netrc", ".htpasswd", ".pgpass", ".git-credentials",
        "id_rsa", "id_dsa", "id_ecdsa", "id_ed25519",
        "credentials", "credentials.json", "service-account.json", "secrets.json", "secrets.yml", "secrets.yaml",
        "token.json", "kubeconfig",
    ]
    /// `client_secret_123.json` (Google OAuth downloads) and friends.
    static let secretNamePrefixes: [String] = ["client_secret", "id_rsa.", "id_ed25519."]
    static let secretExtensions: [String] = [
        "pem", "key", "p12", "pfx", "p8", "ppk", "keystore", "jks", "ovpn", "kdbx", "keychain", "tfstate",
    ]
    /// Anything inside these folders is credentials by definition, whatever it's called.
    static let secretDirectories: [String] = [".ssh", ".aws", ".gnupg", ".kube"]

    static let secretContentPatterns: [(String, String)] = [
        ("-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----", "private key"),
        ("gh[pousr]_[A-Za-z0-9]{36,}", "GitHub token"),
        ("github_pat_[A-Za-z0-9_]{50,}", "GitHub token"),
        ("AKIA[0-9A-Z]{16}", "AWS access key"),
        ("(?i)aws_secret_access_key\\s*[=:]\\s*[\"']?[A-Za-z0-9/+]{40}", "AWS secret key"),
        ("xox[baprs]-[A-Za-z0-9-]{10,}", "Slack token"),
        ("hooks\\.slack\\.com/services/T[A-Za-z0-9]+/B[A-Za-z0-9]+/[A-Za-z0-9]+", "Slack webhook"),
        ("sk-ant-[A-Za-z0-9_-]{20,}", "Anthropic API key"),
        ("sk-(proj-)?[A-Za-z0-9_-]{10,}T3BlbkFJ[A-Za-z0-9_-]{10,}", "OpenAI API key"),
        ("AIza[0-9A-Za-z_-]{35}", "Google API key"),
        ("sk_live_[A-Za-z0-9]{20,}", "Stripe key"),
        ("rk_live_[A-Za-z0-9]{20,}", "Stripe key"),
        ("npm_[A-Za-z0-9]{36}", "npm token"),
        ("pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{50,}", "PyPI token"),
        ("hf_[A-Za-z0-9]{30,}", "Hugging Face token"),
        ("SG\\.[A-Za-z0-9_-]{22}\\.[A-Za-z0-9_-]{43}", "SendGrid key"),
        ("glpat-[A-Za-z0-9_-]{20,}", "GitLab token"),
    ]

    public init() {}

    private static let beginMarker = "# >>> gitstick defaults (managed) >>>"
    private static let endMarker = "# <<< gitstick defaults <<<"

    /// Ensures our managed block exists in .git/info/exclude. Idempotent.
    public func installExcludes(gitDir: URL) throws {
        let infoDir = gitDir.appendingPathComponent("info")
        try FileManager.default.createDirectory(at: infoDir, withIntermediateDirectories: true)
        let file = infoDir.appendingPathComponent("exclude")
        var existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if let start = existing.range(of: Self.beginMarker), let end = existing.range(of: Self.endMarker) {
            existing.removeSubrange(start.lowerBound..<end.upperBound)
        }
        let block = ([Self.beginMarker] + Self.defaultExcludes + [Self.endMarker]).joined(separator: "\n")
        let trimmed = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let content = (trimmed.isEmpty ? "" : trimmed + "\n\n") + block + "\n"
        try content.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Returns a reason to hold back `path` (relative to `root`), or nil if it may be committed.
    public func check(path: String, root: URL) -> HoldReason? {
        let name = (path as NSString).lastPathComponent
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension

        let isExample = lower.hasSuffix(".example") || lower.hasSuffix(".sample") || lower.hasSuffix(".template")
        let secretName = Self.secretNames.contains(lower) || lower.hasPrefix(".env.")
            || Self.secretNamePrefixes.contains(where: { lower.hasPrefix($0) })
        if secretName && !isExample {
            return .looksLikeSecret("file name")
        }
        if Self.secretExtensions.contains(ext) { return .looksLikeSecret(".\(ext) file") }
        if let dir = path.split(separator: "/").dropLast().first(where: { Self.secretDirectories.contains(String($0)) }) {
            return .looksLikeSecret("inside \(dir)/")
        }

        let url = root.appendingPathComponent(path)
        // A dragged-in project with its own .git: git stages it as a gitlink, not as files.
        if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return .nestedRepository }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attrs[.type] as? FileAttributeType) == .typeRegular else { return nil }
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        if size > maxFileBytes { return .tooLarge(bytes: size) }

        if size <= scanContentBytes, let data = try? Data(contentsOf: url),
           !data.prefix(8000).contains(0), // skip binaries
           let text = String(data: data, encoding: .utf8) {
            for (pattern, label) in Self.secretContentPatterns
            where text.range(of: pattern, options: .regularExpression) != nil {
                return .looksLikeSecret(label)
            }
        }
        return nil
    }
}
