import XCTest
@testable import GitstickCore

/// Manual mode's promise: Gitstick never commits on its own, never alters your index,
/// and only pulls when git can do it without touching your uncommitted work.
extension SyncEngineTests {

    func status(_ s: RepoSyncer) -> String { (try? s.git.run(["status", "--porcelain"]).stdout) ?? "" }
    func head(_ s: RepoSyncer) -> String { s.git.value(["rev-parse", "HEAD"]) ?? "" }
    func userCommit(_ s: RepoSyncer, _ msg: String = "my commit") throws {
        try s.git.run(["add", "-A"]); try s.git.run(["commit", "-q", "-m", msg])
    }

    func testManualNeverCommitsOnItsOwn() throws {
        let a = try mac("alpha"); a.mode = .manual
        try write(a, "draft.md", "wip")
        let r = a.syncOnce()
        assertIdle(r)
        XCTAssertNil(r.committed)
        XCTAssertEqual(r.local.uncommitted, 1)
        XCTAssertEqual(status(a), "?? draft.md\n")
    }

    func testManualPushesYourCommits() throws {
        let a = try mac("alpha"), b = try mac("beta"); a.mode = .manual
        try write(a, "index.html", "hi")
        try userCommit(a, "Hand-written message")
        let r = a.syncOnce()
        XCTAssertTrue(r.pushed)
        XCTAssertNil(r.committed)
        b.syncOnce()
        XCTAssertEqual(read(b, "index.html"), "hi")
        XCTAssertEqual(b.git.value(["log", "-1", "--format=%s"]), "Hand-written message")
    }

    func testCommitNowRespectsStaging() throws {
        let a = try mac("alpha"); a.mode = .manual
        try write(a, "ready.txt", "r"); try write(a, "notyet.txt", "n")
        try a.git.run(["add", "ready.txt"])
        let r = a.syncOnce(commitNow: true)
        assertIdle(r)
        XCTAssertEqual(r.committed, "Add ready.txt")
        XCTAssertEqual(status(a), "?? notyet.txt\n")
    }

    func testCommitNowWithNothingStagedCommitsEverything() throws {
        let a = try mac("alpha"); a.mode = .manual
        try write(a, "one.txt", "1"); try write(a, "two.txt", "2")
        let r = a.syncOnce(commitNow: true)
        XCTAssertEqual(r.committed, "Add one.txt and two.txt")
        XCTAssertTrue(r.pushed)
        XCTAssertEqual(status(a), "")
    }

    func testManualPullsAroundUnrelatedDirtyFiles() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "notes.md", "v1"); a.syncOnce(); b.syncOnce()
        a.mode = .manual

        try write(b, "other.txt", "from beta"); b.syncOnce()
        try write(a, "notes.md", "my uncommitted edit")
        let r = a.syncOnce()
        assertIdle(r)
        XCTAssertTrue(r.pulled)
        XCTAssertEqual(read(a, "other.txt"), "from beta")
        XCTAssertEqual(read(a, "notes.md"), "my uncommitted edit")   // untouched
        XCTAssertEqual(status(a), " M notes.md\n")                    // still yours, still uncommitted
    }

    func testManualWaitsWhenIncomingTouchesYourWork() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "notes.md", "v1"); a.syncOnce(); b.syncOnce()
        a.mode = .manual

        try write(b, "notes.md", "beta's edit"); b.syncOnce()
        try write(a, "notes.md", "alpha's uncommitted edit")
        let before = head(a)
        let r = a.syncOnce()
        guard case .waiting(let why) = r.status else { return XCTFail("expected waiting, got \(r.status)") }
        XCTAssertTrue(why.contains("notes.md"), why)
        XCTAssertEqual(read(a, "notes.md"), "alpha's uncommitted edit")
        XCTAssertEqual(head(a), before)
        XCTAssertNil(a.humanActivity())                                // no half-merge left behind
        XCTAssertEqual(r.local.behind, 1)

        // You commit when you're ready; then it's an ordinary keep-both conflict.
        try userCommit(a)
        let r2 = a.syncOnce()
        assertIdle(r2)
        XCTAssertEqual(r2.conflictCopies.count, 1)
        XCTAssertEqual(read(a, "notes.md"), "beta's edit")
        XCTAssertEqual(read(a, r2.conflictCopies[0]), "alpha's uncommitted edit")
        XCTAssertTrue(r2.pushed)
    }

    func testManualNeverMergesOverYourStagedFiles() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        a.mode = .manual

        try write(b, "incoming.txt", "x"); b.syncOnce()
        try write(a, "half-done.txt", "y"); try a.git.run(["add", "half-done.txt"])
        let r = a.syncOnce()
        guard case .waiting = r.status else { return XCTFail("expected waiting, got \(r.status)") }
        XCTAssertNil(read(a, "incoming.txt"))
        XCTAssertEqual(status(a), "A  half-done.txt\n")                // your index, exactly as you left it
    }

    func testPausedTouchesNothing() throws {
        let a = try mac("alpha"); a.mode = .paused
        try write(a, "x.txt", "x")
        let r = a.syncOnce(commitNow: true)
        guard case .paused = r.status else { return XCTFail("expected paused, got \(r.status)") }
        XCTAssertNil(r.committed)
        XCTAssertEqual(r.local.uncommitted, 1)
        XCTAssertEqual(status(a), "?? x.txt\n")
    }

    // Auto mode used to *error* here (the v0.1 known gap). Now it waits, harmlessly.
    func testAutoWaitsWhenHeldBackFileIsInTheWay() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        try write(b, "config.js", "export default {}"); b.syncOnce()
        try write(a, "config.js", "const k = 'ghp_" + String(repeating: "x", count: 36) + "'")
        let r = a.syncOnce()
        guard case .waiting(let why) = r.status else { return XCTFail("expected waiting, got \(r.status)") }
        XCTAssertTrue(why.contains("config.js"), why)
        XCTAssertEqual(r.heldBack.map(\.path), ["config.js"])
        XCTAssertTrue(read(a, "config.js")!.contains("ghp_"))           // your secret, untouched, unpushed
    }

    func testLegacyDriveRecordMigrates() throws {
        let json = #"[{"fullName":"o/r","owner":"o","name":"r","cloneURL":"u","localPath":"/x","autoSync":false},"#
                 + #"{"fullName":"o/s","owner":"o","name":"s","cloneURL":"u","localPath":"/y","autoSync":true}]"#
        let drives = try JSONDecoder().decode([PluggedDrive].self, from: Data(json.utf8))
        XCTAssertEqual(drives.map(\.mode), [.manual, .auto])
        let roundTrip = try JSONDecoder().decode([PluggedDrive].self, from: JSONEncoder().encode(drives))
        XCTAssertEqual(roundTrip, drives)
    }
}
