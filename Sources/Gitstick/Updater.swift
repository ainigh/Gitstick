import AppKit
import GitstickCore

/// Keeps the app on the latest GitHub release: checks at launch, every 6 hours, and on request;
/// installs on request by downloading the release's Gitstick.zip, swapping itself in place, and
/// reopening. Only a bundled .app can do this (`swift run` has nothing to swap).
@MainActor
final class Updater: ObservableObject {
    static let repo = "ainigh/Gitstick"
    static let assetName = "Gitstick.zip"

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
    /// The commit this copy was built from (Scripts/make-app.sh writes it into Info.plist).
    static var currentCommit: String? {
        (Bundle.main.object(forInfoDictionaryKey: "GitstickCommit") as? String).map { String($0.prefix(7)) }
    }
    static var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    enum State: Equatable {
        case idle, checking, upToDate
        case available(Release)
        case installing(String)
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var lastChecked: Date?

    var available: Release? {
        if case .available(let r) = state { return r }
        return nil
    }

    let feed: ReleaseFeed
    /// Runs just before the app quits to relaunch as the new copy (stop the drives cleanly).
    var beforeRelaunch: (() -> Void)?

    init(tokens: TokenProvider) {
        feed = ReleaseFeed(repo: Self.repo, tokens: tokens)
    }

    func start() {
        guard Self.isBundled else { return }
        check(userInitiated: false)
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 6 * 3600 * 1_000_000_000)
                self?.check(userInitiated: false)
            }
        }
    }

    func check(userInitiated: Bool) {
        guard Self.isBundled else { return }
        switch state {
        case .checking, .installing: return
        default: break
        }
        let before = state
        state = .checking
        Task {
            do {
                let latest = try await feed.latest()
                state = latest.isNewer(than: Self.currentVersion) ? .available(latest) : .upToDate
            } catch {
                // A quiet background check that fails shouldn't leave an error in the menu,
                // and an update it already found stays offered.
                if userInitiated { state = .failed(Self.describe(error)) }
                else if case .available = before { state = before }
                else { state = .idle }
            }
            lastChecked = Date()
        }
    }

    func install() {
        guard case .available(let release) = state else { return }
        guard let asset = release.asset(named: Self.assetName) else {
            state = .failed("The release has no \(Self.assetName)"); return
        }
        state = .installing("Downloading \(release.tag)…")
        Task {
            do {
                let fm = FileManager.default
                let app = Bundle.main.bundleURL
                // On the app's own volume, so the swap at the end is a rename.
                let work = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: app, create: true)
                let zip = work.appendingPathComponent(Self.assetName)
                try await feed.download(asset, to: zip)

                state = .installing("Installing…")
                let unpacked = work.appendingPathComponent("unpacked")
                try fm.createDirectory(at: unpacked, withIntermediateDirectories: true)
                try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
                let newApp = unpacked.appendingPathComponent("Gitstick.app")
                guard let newID = Bundle(url: newApp)?.bundleIdentifier, newID == Bundle.main.bundleIdentifier else {
                    throw UpdateError("The download didn't hold Gitstick.app")
                }
                _ = try? Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", newApp.path])

                state = .installing("Restarting…")
                beforeRelaunch?()
                _ = try fm.replaceItemAt(app, withItemAt: newApp)
                try? fm.removeItem(at: work)
                // Start the new copy once this one has quit.
                let relaunch = Process()
                relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
                relaunch.arguments = ["-c", "while kill -0 \(getpid()) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", app.path]
                try relaunch.run()
                NSApp.terminate(nil)
            } catch {
                state = .failed("Update failed: \(Self.describe(error))")
            }
        }
    }

    struct UpdateError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? CustomStringConvertible { return e.description }
        return error.localizedDescription
    }

    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw UpdateError(msg.isEmpty ? "\((tool as NSString).lastPathComponent) failed (\(p.terminationStatus))" : msg)
        }
        return String(decoding: data, as: UTF8.self)
    }
}
