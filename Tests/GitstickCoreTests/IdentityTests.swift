import XCTest
@testable import GitstickCore

/// Who Gitstick commits as. The target user has no global git identity, so this has to work even
/// when the GitHub sign-in finishes after the drives have already started.
extension SyncEngineTests {

    final class IdentityBox: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Git.Identity?
        var identity: Git.Identity? {
            get { lock.lock(); defer { lock.unlock() }; return value }
            set { lock.lock(); value = newValue; lock.unlock() }
        }
    }

    // The identity is looked up on every git call, not frozen when the syncer is created.
    func testIdentityIsResolvedAtCallTime() throws {
        let box = IdentityBox()
        let dir = tmp.appendingPathComponent("gamma")
        try Git(repo: tmp).run(["clone", "-q", remote.path, "gamma"])
        let git = Git(repo: dir, identityProvider: { box.identity })
        try git.run(["checkout", "-q", "-B", "main"])
        // A fresh Mac has no identity of its own (and setUp hides the global config of whoever runs this).
        try git.run(["config", "user.useConfigOnly", "true"])
        let a = RepoSyncer(git: git, deviceName: "gamma")

        try write(a, "late.txt", "l")
        XCTAssertNil(box.identity)
        let first = a.syncOnce()
        guard case .error(let why) = first.status else { return XCTFail("expected error, got \(first.status)") }
        XCTAssertTrue(why.contains("Sign in to GitHub"), why)          // friendly, and says what to do
        XCTAssertNil(first.committed)
        XCTAssertFalse(a.hasCommits())                                   // nothing committed under a wrong name
        XCTAssertEqual(read(a, "late.txt"), "l")                         // the file is untouched, still yours

        box.identity = ("Sam Example", "1+sam@users.noreply.github.com")
        let r = a.syncOnce()
        assertIdle(r)
        XCTAssertEqual(git.value(["log", "-1", "--format=%an <%ae>"]), "Sam Example <1+sam@users.noreply.github.com>")
        XCTAssertEqual(git.value(["log", "-1", "--format=%s"]), "Add late.txt")
    }

    // A drive that couldn't commit for lack of an identity doesn't wait for the next poll.
    func testLearningTheIdentityTriggersASync() throws {
        let state = tmp.appendingPathComponent("state")
        let m = DriveManager(root: tmp.appendingPathComponent("drives"), stateDir: state, tokens: TokenProvider())
        XCTAssertNil(m.identity)
        m.identity = ("Sam Example", "sam@example.com")

        // …and it's remembered for the next launch, so sign-in needn't finish before the first commit.
        let again = DriveManager(root: tmp.appendingPathComponent("drives"), stateDir: state, tokens: TokenProvider())
        XCTAssertEqual(again.identity?.name, "Sam Example")
        XCTAssertEqual(again.identity?.email, "sam@example.com")
        again.identity = nil
        XCTAssertNil(DriveManager(root: tmp.appendingPathComponent("drives"), stateDir: state, tokens: TokenProvider()).identity)
    }

    // Not signed in: the GitHub CLI is asked once a minute, not once per git command.
    func testMissingTokenDoesNotSpawnTheCLIOnEveryCall() {
        let calls = IdentityBox()      // reused as a thread-safe counter: .identity?.name holds the count
        let tokens = TokenProvider()
        tokens.environment = [:]                // whatever $GITHUB_TOKEN the test runner has is not the point
        tokens.cliLookup = { calls.identity = ("\((Int(calls.identity?.name ?? "0") ?? 0) + 1)", ""); return nil }
        for _ in 0..<50 { XCTAssertNil(tokens.token()) }
        XCTAssertEqual(calls.identity?.name, "1")

        tokens.retryAfter = 0                   // the grace period is over: ask again
        XCTAssertNil(tokens.token())
        XCTAssertEqual(calls.identity?.name, "2")

        tokens.cliLookup = { calls.identity = ("hit", ""); return "ghp_fromcli" }
        tokens.invalidate()                     // sign-in happened: look again, and a hit sticks
        XCTAssertEqual(tokens.token(), "ghp_fromcli")
        tokens.cliLookup = { XCTFail("a cached token must not be looked up again"); return nil }
        XCTAssertEqual(tokens.token(), "ghp_fromcli")
    }

    func testIdentityErrorIsHumanized() {
        let raw = GitError(args: ["commit"], result: GitResult(status: 128, stdoutData: Data(),
            stderr: "Author identity unknown\n\n*** Please tell me who you are.\n"))
        XCTAssertTrue(RepoSyncer.humanize(raw).hasPrefix("Can't commit yet"))
    }
}
