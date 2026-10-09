import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A "PC": a GitHub account or organization.
public struct PC: Identifiable, Hashable, Codable, Sendable {
    public var id: String { login }
    public let login: String
    public let isOrg: Bool
    public var drives: [RemoteDrive]
}

/// A "drive" as listed on GitHub (not necessarily plugged in).
public struct RemoteDrive: Identifiable, Hashable, Codable, Sendable {
    public var id: String { fullName }
    public let fullName: String        // owner/name
    public let name: String
    public let owner: String
    public let isPrivate: Bool
    public let defaultBranch: String
    public let cloneURL: String
    public let canWrite: Bool
    public let archived: Bool
    public let sizeKB: Int
    public let pushedAt: String?
}

/// Where the GitHub token comes from. Order: explicit (Keychain / pasted), $GITHUB_TOKEN, `gh auth token`.
public final class TokenProvider: CredentialSource, @unchecked Sendable {
    private var cached: String?
    private let lock = NSLock()
    public var explicit: (() -> String?)?

    public init(explicit: (() -> String?)? = nil) { self.explicit = explicit }

    public func token() -> String? {
        lock.lock(); defer { lock.unlock() }
        if let t = explicit?(), !t.isEmpty { return t }
        if let cached { return cached }
        if let env = ProcessInfo.processInfo.environment["GITHUB_TOKEN"], !env.isEmpty { cached = env; return env }
        if let gh = Self.fromGHCLI() { cached = gh; return gh }
        return nil
    }

    public func invalidate() { lock.lock(); cached = nil; lock.unlock() }

    /// Reuse the GitHub CLI's login if present — zero-setup for people who already use `gh`.
    static func fromGHCLI() -> String? {
        for path in ["/opt/homebrew/bin/gh", "/usr/local/bin/gh", "/usr/bin/gh"]
        where FileManager.default.isExecutableFile(atPath: path) {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: path)
            p.arguments = ["auth", "token"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            let t = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if p.terminationStatus == 0, !t.isEmpty { return t }
        }
        return nil
    }
}

public struct GitHubUser: Codable, Sendable {
    public let login: String
    public let name: String?
    public let id: Int
    /// Commit identity that GitHub attributes to this account without exposing a real email.
    public var noreplyEmail: String { "\(id)+\(login)@users.noreply.github.com" }
}

public enum GitHubError: Error, CustomStringConvertible {
    case notSignedIn, http(Int, String)
    public var description: String {
        switch self {
        case .notSignedIn: return "Not signed in to GitHub"
        case .http(let code, let body): return "GitHub API \(code): \(body.prefix(200))"
        }
    }
}

/// Lists the "PCs" and "drives" for the signed-in user.
public struct GitHubCatalog: Sendable {
    public let tokens: TokenProvider
    public var api = URL(string: "https://api.github.com")!

    public init(tokens: TokenProvider) { self.tokens = tokens }

    public func me() async throws -> GitHubUser {
        try JSONDecoder().decode(GitHubUser.self, from: try await get("/user").first!)
    }

    /// All repos the user can see, grouped into PCs (the user first, then orgs, alphabetically).
    public func pcs() async throws -> [PC] {
        let user = try await me()
        struct Org: Decodable { let login: String }
        let orgs = try await get("/user/orgs?per_page=100").flatMap { try JSONDecoder().decode([Org].self, from: $0) }

        struct Repo: Decodable {
            struct Owner: Decodable { let login: String; let type: String }
            struct Perms: Decodable { let push: Bool? }
            let full_name: String, name: String, owner: Owner, `private`: Bool
            let default_branch: String?, clone_url: String, permissions: Perms?
            let archived: Bool?, size: Int?, pushed_at: String?
        }
        let repos = try await get("/user/repos?per_page=100&affiliation=owner,collaborator,organization_member&sort=pushed")
            .flatMap { try JSONDecoder().decode([Repo].self, from: $0) }

        var byOwner: [String: PC] = [:]
        byOwner[user.login] = PC(login: user.login, isOrg: false, drives: [])
        for o in orgs { byOwner[o.login] = PC(login: o.login, isOrg: true, drives: []) }
        for r in repos {
            let drive = RemoteDrive(
                fullName: r.full_name, name: r.name, owner: r.owner.login, isPrivate: r.private,
                defaultBranch: r.default_branch ?? "main", cloneURL: r.clone_url,
                canWrite: r.permissions?.push ?? false, archived: r.archived ?? false,
                sizeKB: r.size ?? 0, pushedAt: r.pushed_at)
            byOwner[r.owner.login, default: PC(login: r.owner.login, isOrg: r.owner.type == "Organization", drives: [])]
                .drives.append(drive)
        }
        return byOwner.values.sorted {
            if ($0.login == user.login) != ($1.login == user.login) { return $0.login == user.login }
            return $0.login.lowercased() < $1.login.lowercased()
        }
    }

    /// GET with pagination via the Link header. Returns one Data per page.
    func get(_ path: String) async throws -> [Data] {
        guard let token = tokens.token() else { throw GitHubError.notSignedIn }
        var pages: [Data] = []
        var next: URL? = URL(string: path, relativeTo: api)
        while let url = next, pages.count < 20 {
            var req = URLRequest(url: url)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
            let (data, resp) = try await URLSession.shared.bytes(of: req)
            let http = resp as? HTTPURLResponse
            guard let code = http?.statusCode, (200..<300).contains(code) else {
                if http?.statusCode == 401 { tokens.invalidate(); throw GitHubError.notSignedIn }
                throw GitHubError.http(http?.statusCode ?? -1, String(decoding: data, as: UTF8.self))
            }
            pages.append(data)
            next = Self.nextLink(http?.value(forHTTPHeaderField: "Link"))
        }
        return pages
    }

    static func nextLink(_ header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") where part.contains("rel=\"next\"") {
            if let s = part.firstIndex(of: "<"), let e = part.firstIndex(of: ">") {
                return URL(string: String(part[part.index(after: s)..<e]))
            }
        }
        return nil
    }
}

extension URLSession {
    /// `data(for:)` is async-native on Apple platforms but missing from swift-corelibs-foundation
    /// (Linux), where the engine and tests also build for CI. Same semantics, one code path.
    func bytes(of request: URLRequest) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { cont in
            dataTask(with: request) { data, response, error in
                if let error { cont.resume(throwing: error) }
                else if let response { cont.resume(returning: (data ?? Data(), response)) }
                else { cont.resume(throwing: URLError(.badServerResponse)) }
            }.resume()
        }
    }
}
