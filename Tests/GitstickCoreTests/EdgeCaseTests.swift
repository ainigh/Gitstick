import XCTest
@testable import GitstickCore

/// The awkward corners: things a "drop files and walk away" user will hit sooner or later.
extension SyncEngineTests {

    // Someone drags a whole project folder — one that has its own .git — into the drive.
    // Git would commit it as an empty "gitlink"; the other Mac would see an empty folder.
    func testNestedRepoIsHeldBack() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        let nested = a.git.repo.appendingPathComponent("myproj")
        try write(a, "myproj/file.txt", "hi")
        let inner = Git(repo: nested, identity: (name: "x", email: "x@example.com"))
        try inner.run(["init", "-q"]); try inner.run(["add", "."]); try inner.run(["commit", "-q", "-m", "init"])
        try write(a, "ok.txt", "fine")

        let r = a.syncOnce()
        assertIdle(r)
        XCTAssertEqual(r.committed, "Add ok.txt")
        XCTAssertEqual(r.heldBack.map(\.path), ["myproj"])
        XCTAssertEqual(status(a), "?? myproj/\n")                      // still yours, still on disk
        b.syncOnce()
        XCTAssertFalse(FileManager.default.fileExists(atPath: b.git.repo.appendingPathComponent("myproj").path))
    }

    // One Mac makes "thing" a file, the other makes it a folder.
    func testFileVersusFolderKeepsBoth() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        try write(a, "thing/inner.txt", "inside"); assertIdle(a.syncOnce())
        try write(b, "thing", "flat")
        let rb = b.syncOnce()
        assertIdle(rb)
        XCTAssertEqual(read(b, "thing/inner.txt"), "inside")
        guard rb.conflictCopies.count == 1 else { return XCTFail("expected one conflict copy, got \(rb)") }
        XCTAssertEqual(read(b, rb.conflictCopies[0]), "flat")
        XCTAssertTrue(rb.conflictCopies[0].hasPrefix("thing (conflict from beta"), rb.conflictCopies[0])
        XCTAssertNil(a.humanActivity())
        assertIdle(a.syncOnce())
        XCTAssertEqual(read(a, rb.conflictCopies[0]), "flat")
    }

    // The mirror image: the folder is here, the file arrives from GitHub. The folder stays.
    func testFolderVersusIncomingFileKeepsBoth() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "seed", "s"); a.syncOnce(); b.syncOnce()
        try write(a, "thing", "flat"); assertIdle(a.syncOnce())
        try write(b, "thing/inner.txt", "inside")
        let rb = b.syncOnce()
        assertIdle(rb)
        XCTAssertEqual(read(b, "thing/inner.txt"), "inside")
        guard rb.conflictCopies.count == 1 else { return XCTFail("expected one conflict copy, got \(rb)") }
        XCTAssertEqual(read(b, rb.conflictCopies[0]), "flat")
        XCTAssertTrue(rb.conflictCopies[0].hasPrefix("thing (conflict from GitHub"), rb.conflictCopies[0])
        XCTAssertEqual(status(b), "")
        assertIdle(a.syncOnce())
        XCTAssertEqual(read(a, "thing/inner.txt"), "inside")
        XCTAssertEqual(read(a, rb.conflictCopies[0]), "flat")
    }

    // VS Code's background `git status` holds index.lock for a moment. That's not a human at work.
    func testTransientIndexLockIsWaitedOut() throws {
        let a = try mac("alpha")
        try write(a, "x.txt", "x")
        let lock = a.git.gitDir.appendingPathComponent("index.lock")
        _ = FileManager.default.createFile(atPath: lock.path, contents: Data())
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) { try? FileManager.default.removeItem(at: lock) }
        let r = a.syncOnce()
        assertIdle(r)
        XCTAssertEqual(r.committed, "Add x.txt")

        // …but a lock that stays is respected.
        a.lockGracePeriod = 0.3
        _ = FileManager.default.createFile(atPath: lock.path, contents: Data())
        guard case .paused = a.syncOnce().status else { return XCTFail("expected paused") }
    }

    // The token reaches git as a per-command header and never appears on the command line.
    func testTokenTravelsThroughEnvironmentNotArguments() throws {
        struct Fixed: CredentialSource { func token() -> String? { "ghp_secret" } }
        let a = try mac("alpha")
        let git = Git(repo: a.git.repo, credentials: Fixed())
        let header = git.value(["config", "http.https://github.com/.extraheader"])
        XCTAssertEqual(header, "AUTHORIZATION: basic " + Data("x-access-token:ghp_secret".utf8).base64EncodedString())
        XCTAssertNil(a.git.value(["config", "http.https://github.com/.extraheader"]))   // nothing persisted
        XCTAssertNil(Git(repo: a.git.repo).value(["config", "http.https://github.com/.extraheader"]))
    }

    // Binary files can't be merged line by line; both versions must survive byte for byte.
    func testBinaryConflictKeepsBoth() throws {
        let a = try mac("alpha"), b = try mac("beta")
        let base = Data([0, 1, 2]), va = Data([0, 1, 3]), vb = Data([0, 1, 4])
        try base.write(to: a.git.repo.appendingPathComponent("img.bin")); a.syncOnce(); b.syncOnce()
        try va.write(to: a.git.repo.appendingPathComponent("img.bin")); assertIdle(a.syncOnce())
        try vb.write(to: b.git.repo.appendingPathComponent("img.bin"))
        let rb = b.syncOnce()
        assertIdle(rb)
        XCTAssertEqual(try Data(contentsOf: b.git.repo.appendingPathComponent("img.bin")), va)
        XCTAssertEqual(try Data(contentsOf: b.git.repo.appendingPathComponent(rb.conflictCopies[0])), vb)
    }

    // The executable bit of a conflicting script survives on the conflict copy.
    func testConflictCopyKeepsExecutableBit() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "run.sh", "#!/bin/sh\necho 1\n")
        let path = a.git.repo.appendingPathComponent("run.sh").path
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        a.syncOnce(); b.syncOnce()
        try write(a, "run.sh", "#!/bin/sh\necho 2\n"); a.syncOnce()
        try write(b, "run.sh", "#!/bin/sh\necho 3\n")
        let rb = b.syncOnce()
        assertIdle(rb)
        let copyPerms = try FileManager.default.attributesOfItem(atPath: b.git.repo.appendingPathComponent(rb.conflictCopies[0]).path)[.posixPermissions] as? Int
        XCTAssertEqual((copyPerms ?? 0) & 0o111, 0o111)
        XCTAssertEqual(b.git.value(["ls-files", "-s", "--", rb.conflictCopies[0]])?.prefix(6), "100755")
    }

    // Two Macs each make the first commit into an empty repo: histories are joined, not refused.
    func testTwoFirstCommitsIntoEmptyRepoAreJoined() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "a.txt", "a"); try write(b, "b.txt", "b")
        assertIdle(a.syncOnce())
        // beta commits locally (no remote yet seen) then finds alpha's root commit on push.
        let rb = b.syncOnce()
        assertIdle(rb)
        XCTAssertTrue(rb.pushed)
        XCTAssertEqual(read(b, "a.txt"), "a")
        assertIdle(a.syncOnce())
        XCTAssertEqual(read(a, "b.txt"), "b")
    }

    // Branch protection on GitHub: the work goes to a side branch instead of failing.
    func testProtectedBranchDiverts() throws {
        let a = try mac("alpha")
        try write(a, "seed", "s"); assertIdle(a.syncOnce())
        let hook = remote.appendingPathComponent("hooks/pre-receive")
        try """
        #!/bin/sh
        while read old new ref; do
          if [ "$ref" = "refs/heads/main" ]; then echo "remote: error: GH006: Protected branch update failed for refs/heads/main." >&2; exit 1; fi
        done
        exit 0
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        try write(a, "work.txt", "w")
        let r = a.syncOnce()
        guard case .divertedTo(let side) = r.status else { return XCTFail("expected diverted, got \(r.status)") }
        XCTAssertEqual(side, "gitstick/alpha")
        XCTAssertTrue(r.pushed)
        XCTAssertNotNil(Git(repo: remote).value(["rev-parse", "--verify", "-q", "refs/heads/gitstick/alpha"]))
        XCTAssertEqual(Git(repo: remote).value(["show", "refs/heads/gitstick/alpha:work.txt"]), "w")
    }

    // Many requests during one cycle collapse into exactly one follow-up cycle.
    func testRequestsCoalesce() throws {
        let a = try mac("alpha")
        try write(a, "x.txt", "x")
        let lock = NSLock()
        var reports = 0
        let done = expectation(description: "settled")
        a.onReport = { _ in
            lock.lock(); reports += 1; lock.unlock()
        }
        for _ in 0..<20 { a.requestSync() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { done.fulfill() }
        wait(for: [done], timeout: 15)
        lock.lock(); let n = reports; lock.unlock()
        XCTAssertTrue((1...2).contains(n), "expected 1–2 cycles, got \(n)")
        XCTAssertEqual(a.git.value(["log", "--oneline", "--format=%s"]), "Add x.txt")
    }

    // Deleting a folder here while the other Mac edited a file inside: the edit wins, the rest goes.
    func testFolderDeleteVersusEditInside() throws {
        let a = try mac("alpha"), b = try mac("beta")
        try write(a, "docs/keep.md", "k"); try write(a, "docs/gone.md", "g"); a.syncOnce(); b.syncOnce()
        try FileManager.default.removeItem(at: a.git.repo.appendingPathComponent("docs"))
        try write(b, "docs/keep.md", "edited")
        assertIdle(a.syncOnce())
        assertIdle(b.syncOnce())
        assertIdle(a.syncOnce())
        XCTAssertEqual(read(a, "docs/keep.md"), "edited")
        XCTAssertNil(read(a, "docs/gone.md"))
    }
}
