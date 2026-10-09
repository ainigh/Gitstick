import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// A version like "0.3.12" (a leading "v" is fine). Compared number by number: 0.3.12 > 0.3.9.
public struct Version: Comparable, CustomStringConvertible, Sendable {
    public let parts: [Int]

    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".").map { Int($0) }
        guard !parts.isEmpty, !parts.contains(where: { $0 == nil }) else { return nil }
        self.parts = parts.compactMap { $0 }
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: Version, b: Version) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0, y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: Version, b: Version) -> Bool { !(a < b) && !(b < a) }
}

/// The bits of a GitHub release the updater needs (GET /repos/{owner}/{repo}/releases/latest).
public struct Release: Decodable, Equatable, Sendable {
    public struct Asset: Decodable, Equatable, Sendable {
        public let name: String
        /// Works without a token on a public repo.
        public let browserDownloadURL: URL
        /// The API URL; with a token and `Accept: application/octet-stream` it works on a private repo too.
        public let apiURL: URL

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
            case apiURL = "url"
        }
    }

    public let tag: String
    /// The commit the release was made from (CI passes the sha).
    public let target: String?
    public let notes: String?
    public let page: URL?
    public let assets: [Asset]

    enum CodingKeys: String, CodingKey {
        case tag = "tag_name"
        case target = "target_commitish"
        case notes = "body"
        case page = "html_url"
        case assets
    }

    public static func decode(_ data: Data) throws -> Release {
        try JSONDecoder().decode(Release.self, from: data)
    }

    public var version: Version? { Version(tag) }
    public func asset(named name: String) -> Asset? { assets.first { $0.name == name } }
    /// The first line of the notes: the commit subject, as CI writes it.
    public var title: String { notes?.components(separatedBy: "\n").first ?? tag }

    /// Whether this release is newer than the copy that's running. A copy whose version doesn't
    /// parse (a dev build run with `swift run`) is never offered an update; a local build from
    /// `Scripts/make-app.sh` is 0.0.0, so the first real release is.
    public func isNewer(than running: String) -> Bool {
        guard let mine = Version(running), let theirs = version else { return false }
        return mine < theirs
    }
}

/// Reads releases from GitHub. The token is optional: a public repo answers without one.
public struct ReleaseFeed: Sendable {
    public let repo: String
    public let tokens: TokenProvider?
    public var api = URL(string: "https://api.github.com")!

    public init(repo: String, tokens: TokenProvider? = nil) {
        self.repo = repo
        self.tokens = tokens
    }

    public func latest() async throws -> Release {
        var req = URLRequest(url: URL(string: "/repos/\(repo)/releases/latest", relativeTo: api)!)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let token = tokens?.token() { req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, resp) = try await URLSession.shared.bytes(of: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else {
            if code == 404 { throw GitHubError.http(404, "no release yet") }
            throw GitHubError.http(code, String(decoding: data, as: UTF8.self))
        }
        return try Release.decode(data)
    }

    /// Downloads a release asset to `file`.
    public func download(_ asset: Release.Asset, to file: URL) async throws {
        var req: URLRequest
        if let token = tokens?.token() {
            req = URLRequest(url: asset.apiURL)
            req.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        } else {
            req = URLRequest(url: asset.browserDownloadURL)
        }
        let (data, resp) = try await URLSession.shared.bytes(of: req)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw GitHubError.http(code, "download failed") }
        try data.write(to: file, options: .atomic)
    }
}
