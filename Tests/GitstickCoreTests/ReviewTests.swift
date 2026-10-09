import XCTest
@testable import GitstickCore

/// Pull policy `.review`: outgoing stays frictionless, incoming waits for a yes.
extension SyncEngineTests {

    func incoming(_ r: SyncReport, file: StaticString = #filePath, line: UInt = #line) -> IncomingChanges? {
        guard case .incoming(let c) = r.status else { XCTFail("expected incoming, got \(r.status)", file: file, line: line); return nil }
        return c
    }

    func testReviewHoldsIncomingUntilAccepted() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        a.pullPolicy = .review

        try write(b, "new.txt", "from beta"); try write(b, "seed", "changed"); assertIdle(b.syncOnce())
        let before = head(a)
        let r = a.syncOnce()
        guard let c = incoming(r) else { return }
        XCTAssertEqual(c.commits.map(\.author), ["beta"])
        XCTAssertEqual(c.commits.first?.subject, "Add new.txt, update seed")
        XCTAssertEqual(Set(c.files.map(\.path)), ["new.txt", "seed"])
        XCTAssertTrue(c.alsoChangedHere.isEmpty)
        XCTAssertFalse(c.declined)
        XCTAssertEqual(head(a), before)                      // nothing merged
        XCTAssertNil(read(a, "new.txt"))
        XCTAssertEqual(r.local.behind, 1)

        // Asking again changes nothing and reports the same thing.
        XCTAssertEqual(incoming(a.syncOnce()), c)

        a.acceptIncoming(c)
        let r2 = a.syncOnce()
        assertIdle(r2)
        XCTAssertTrue(r2.pulled)
        XCTAssertEqual(read(a, "new.txt"), "from beta")
    }

    func testReviewStillPushesYourWorkWhenGitHubIsNotAhead() throws {
        let a = try mac("alpha"), b = try mac("beta")
        a.pullPolicy = .review
        try write(a, "mine.txt", "m")
        let r = a.syncOnce()
        assertIdle(r)
        XCTAssertTrue(r.pushed)
        b.syncOnce()
        XCTAssertEqual(read(b, "mine.txt"), "m")
    }

    func testDeclineHoldsOffQuietlyUntilGitHubMovesOn() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        a.pullPolicy = .review
        try write(b, "one.txt", "1"); b.syncOnce()

        guard let c = incoming(a.syncOnce()) else { return }
        a.declineIncoming(c)
        guard let held = incoming(a.syncOnce()) else { return }
        XCTAssertTrue(held.declined)
        XCTAssertEqual(held.remoteHead, c.remoteHead)
        XCTAssertNil(read(a, "one.txt"))

        // Your own work keeps getting committed (and waits, since GitHub is ahead).
        try write(a, "mine.txt", "m")
        let r = a.syncOnce()
        XCTAssertEqual(r.committed, "Add mine.txt")
        XCTAssertEqual(r.local.ahead, 1)
        XCTAssertNotNil(incoming(r))

        // GitHub moves on: a fresh question, not a stale decline.
        try write(b, "two.txt", "2"); b.syncOnce()
        guard let again = incoming(a.syncOnce()) else { return }
        XCTAssertFalse(again.declined)
        XCTAssertEqual(again.commits.count, 2)

        // Accepting merges everything, pushes your waiting commit, and beta catches up.
        a.acceptIncoming(again)
        let r2 = a.syncOnce()
        assertIdle(r2)
        XCTAssertTrue(r2.pushed)
        XCTAssertEqual(read(a, "two.txt"), "2")
        b.syncOnce()
        XCTAssertEqual(read(b, "mine.txt"), "m")
    }

    func testReviewWarnsAboutFilesAlsoChangedHere() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "notes.md", "v1"); a.syncOnce(); b.syncOnce()
        a.pullPolicy = .review
        try write(b, "notes.md", "beta"); try write(b, "other.md", "o"); b.syncOnce()
        try write(a, "notes.md", "alpha")
        guard let c = incoming(a.syncOnce()) else { return }
        XCTAssertEqual(c.alsoChangedHere, ["notes.md"])
        a.acceptIncoming(c)
        let r = a.syncOnce()
        assertIdle(r)
        XCTAssertEqual(r.conflictCopies.count, 1)              // the usual keep-both
        XCTAssertEqual(read(a, "notes.md"), "beta")
    }

    func testDecisionsSurviveARelaunch() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        a.pullPolicy = .review
        try write(b, "x.txt", "x"); b.syncOnce()
        guard let c = incoming(a.syncOnce()) else { return }
        a.acceptIncoming(c)

        let relaunched = RepoSyncer(git: a.git, deviceName: "alpha")
        relaunched.pullPolicy = .review
        assertIdle(relaunched.syncOnce())
        XCTAssertEqual(read(a, "x.txt"), "x")
    }

    func testSwitchingBackToAutomaticBringsHeldChangesIn() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        a.pullPolicy = .review
        try write(b, "x.txt", "x"); b.syncOnce()
        guard let c = incoming(a.syncOnce()) else { return }
        a.declineIncoming(c)
        a.pullPolicy = .automatic
        assertIdle(a.syncOnce())
        XCTAssertEqual(read(a, "x.txt"), "x")
    }

    func testDriveRecordRoundTripsPullPolicy() throws {
        let d = PluggedDrive(fullName: "o/r", owner: "o", name: "r", cloneURL: "u", localPath: "/x", mode: .auto, pullPolicy: .review)
        let back = try JSONDecoder().decode(PluggedDrive.self, from: JSONEncoder().encode(d))
        XCTAssertEqual(back.pullPolicy, .review)
        let legacy = #"{"fullName":"o/r","owner":"o","name":"r","cloneURL":"u","localPath":"/x","mode":"auto"}"#
        XCTAssertEqual(try JSONDecoder().decode(PluggedDrive.self, from: Data(legacy.utf8)).pullPolicy, .automatic)
    }
}
