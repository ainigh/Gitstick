import XCTest
@testable import GitstickCore

/// Two "Macs" sharing one "GitHub" (a bare repo on disk).
final class SyncEngineTests: XCTestCase { 
    var tmp: URL!
    var remote: URL!

    override func setUpWithError() throws {
        // The suite must not depend on whoever runs it: no global identity, signing, hooks, or aliases.
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent("gitstick-tests-\(UUID().uuidString)")
        remote = tmp.appendingPathComponent("remote.git")
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        try Git(repo: remote).run(["init", "-q", "--bare", "-b", "main"])
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func mac(_ name: String) throws -> RepoSyncer {
        let dir = tmp.appendingPathComponent(name)
        try Git(repo: tmp).run(["clone", "-q", remote.path, name])
        let git = Git(repo: dir, identity: (name: name, email: "\(name)@example.com"))
        try git.run(["checkout", "-q", "-B", "main"])
        return RepoSyncer(git: git, deviceName: name)
    }

    func write(_ s: RepoSyncer, _ path: String, _ text: String) throws {
        let url = s.git.repo.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    func read(_ s: RepoSyncer, _ path: String) -> String? {
        try? String(contentsOf: s.git.repo.appendingPathComponent(path), encoding: .utf8)
    }

    func assertIdle(_ r: SyncReport, file: StaticString = #filePath, line: UInt = #line) {
        guard case .idle = r.status else { return XCTFail("expected idle, got \(r.status)", file: file, line: line) }
    }

    // Drop a file, it shows up on the other Mac. No questions asked.
    func testDropFileAndGo() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "index.html", "<h1>hi</h1>")
        let ra = a.syncOnce()
        assertIdle(ra)
        XCTAssertEqual(ra.committed, "Add index.html")
        XCTAssertTrue(ra.pushed)

        let rb = b.syncOnce()
        assertIdle(rb)
        XCTAssertEqual(read(b, "index.html"), "<h1>hi</h1>")
    }

    // Both edit the same file: nobody loses anything, nobody gets asked.
    func testConflictKeepsBoth() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "notes.md", "base")
        a.syncOnce(); b.syncOnce()

        try write(a, "notes.md", "alpha's version")
        try write(b, "notes.md", "beta's version")
        assertIdle(a.syncOnce())
        let rb = b.syncOnce()
        assertIdle(rb)
        XCTAssertEqual(rb.conflictCopies.count, 1)
        XCTAssertEqual(read(b, "notes.md"), "alpha's version")             // remote keeps the name
        XCTAssertEqual(read(b, rb.conflictCopies[0]), "beta's version")    // local saved alongside
        XCTAssertTrue(rb.conflictCopies[0].contains("conflict from beta"))

        // And alpha converges to the same state.
        assertIdle(a.syncOnce())
        XCTAssertEqual(read(a, rb.conflictCopies[0]), "beta's version")
    }

    // Edit beats delete.
    func testEditWinsOverDelete() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "doc.txt", "v1")
        a.syncOnce(); b.syncOnce()

        try FileManager.default.removeItem(at: a.git.repo.appendingPathComponent("doc.txt"))
        try write(b, "doc.txt", "v2")
        assertIdle(a.syncOnce())
        assertIdle(b.syncOnce())
        XCTAssertEqual(read(b, "doc.txt"), "v2")
        assertIdle(a.syncOnce())
        XCTAssertEqual(read(a, "doc.txt"), "v2")
    }

    // Non-overlapping edits merge cleanly.
    func testIndependentChangesMerge() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "a.txt", "a"); try write(b, "b.txt", "b")
        a.syncOnce()
        let rb = b.syncOnce()
        assertIdle(rb)
        XCTAssertTrue(rb.conflictCopies.isEmpty)
        a.syncOnce()
        XCTAssertEqual(read(a, "b.txt"), "b")
        XCTAssertEqual(read(b, "a.txt"), "a")
    }

    // Secrets and junk never leave the Mac.
    func testGatekeeper() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, ".env", "API_KEY=123")
        try write(a, "config.js", "const k = 'ghp_" + String(repeating: "x", count: 36) + "'")
        try write(a, ".DS_Store", "junk")
        try write(a, "ok.txt", "fine")
        let r = a.syncOnce()
        assertIdle(r)
        XCTAssertEqual(Set(r.heldBack.map(\.path)), [".env", "config.js"])
        XCTAssertEqual(r.committed, "Add ok.txt")
        b.syncOnce()
        XCTAssertNil(read(b, ".env"))
        XCTAssertNil(read(b, ".DS_Store"))
        XCTAssertNotNil(read(a, ".env"))     // still on disk locally
    }

    // If a human is mid-merge/rebase, we don't touch anything.
    func testBacksOffDuringManualGit() throws {
        let a = try mac("alpha")
        try write(a, "x.txt", "x")
        _ = FileManager.default.createFile(atPath: a.git.gitDir.appendingPathComponent("MERGE_HEAD").path, contents: Data())
        let r = a.syncOnce()
        guard case .paused = r.status else { return XCTFail("expected paused, got \(r.status)") }
        XCTAssertNil(r.committed)
    }

    // Someone pushed between our fetch and push: we retry, not fail.
    func testRaceRetry() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        try write(b, "b.txt", "b"); b.syncOnce()          // remote moves ahead
        try write(a, "a.txt", "a")
        let r = a.syncOnce()                               // must fetch, merge, push
        assertIdle(r)
        XCTAssertTrue(r.pushed)
        XCTAssertEqual(read(a, "b.txt"), "b")
    }

    func testCommitMessages() {
        XCTAssertEqual(CommitMessage.make(from: [("A", "site/index.html")]).components(separatedBy: "\n")[0], "Add index.html")
        XCTAssertEqual(CommitMessage.make(from: [("A", "a"), ("M", "b")]).components(separatedBy: "\n")[0], "Add a, update b")
        XCTAssertEqual(CommitMessage.make(from: (1...5).map { ("M", "f\($0)") }).components(separatedBy: "\n")[0], "Update 5 files")
    }

    func testPushFailureClassification() {
        XCTAssertEqual(RepoSyncer.classifyPushFailure("! [rejected] main -> main (fetch first)"), .raced)
        XCTAssertEqual(RepoSyncer.classifyPushFailure("remote: error: GH006: Protected branch update failed"), .protected)
    }
}
