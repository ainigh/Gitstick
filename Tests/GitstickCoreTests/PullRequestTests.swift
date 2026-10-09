import XCTest
@testable import GitstickCore
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// I9, second half: diverted work doesn't just sit on a side branch, it gets a pull request.
final class PullRequestTests: XCTestCase {

    /// A stand-in for api.github.com: records what was asked and answers from a script.
    final class FakeGitHub: @unchecked Sendable {
        struct Call { let method: String; let url: String; let body: [String: String]? }
        private let lock = NSLock()
        private(set) var calls: [Call] = []
        var openPRs: [String] = []                 // html_urls GET returns
        var createStatus = 201
        var created = "https://github.com/o/r/pull/7"

        func transport(_ req: URLRequest) async throws -> (Data, URLResponse) {
            let body = req.httpBody.flatMap { try? JSONDecoder().decode([String: String].self, from: $0) }
            lock.lock()
            calls.append(Call(method: req.httpMethod ?? "GET", url: req.url!.absoluteString, body: body))
            lock.unlock()
            func reply(_ status: Int, _ json: String) -> (Data, URLResponse) {
                (Data(json.utf8), HTTPURLResponse(url: req.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            if req.httpMethod == "POST" {
                return reply(createStatus, createStatus == 201 ? #"{"html_url": "\#(created)"}"# : #"{"message": "Validation Failed"}"#)
            }
            return reply(200, "[" + openPRs.map { #"{"html_url": "\#($0)"}"# }.joined(separator: ",") + "]")
        }
    }

    func catalog(_ fake: FakeGitHub) -> GitHubCatalog {
        var c = GitHubCatalog(tokens: TokenProvider(explicit: { "ghp_test" }))
        c.transport = { try await fake.transport($0) }
        return c
    }

    func testOpensAPullRequestWhenThereIsNone() async throws {
        let fake = FakeGitHub()
        let url = try await catalog(fake).pullRequest(repo: "o/r", head: "gitstick/alpha", base: "main", title: "T", body: "B")
        XCTAssertEqual(url?.absoluteString, "https://github.com/o/r/pull/7")
        XCTAssertEqual(fake.calls.map(\.method), ["GET", "POST"])
        XCTAssertEqual(fake.calls[0].url, "https://api.github.com/repos/o/r/pulls?state=open&head=o:gitstick/alpha&base=main&per_page=1")
        XCTAssertEqual(fake.calls[1].url, "https://api.github.com/repos/o/r/pulls")
        XCTAssertEqual(fake.calls[1].body, ["title": "T", "head": "gitstick/alpha", "base": "main", "body": "B"])
    }

    func testReusesTheOpenPullRequest() async throws {
        let fake = FakeGitHub()
        fake.openPRs = ["https://github.com/o/r/pull/3"]
        let url = try await catalog(fake).pullRequest(repo: "o/r", head: "gitstick/alpha", base: "main", title: "T", body: "B")
        XCTAssertEqual(url?.absoluteString, "https://github.com/o/r/pull/3")
        XCTAssertEqual(fake.calls.map(\.method), ["GET"])
    }

    func testNothingToMergeIsNotAnError() async throws {
        let fake = FakeGitHub()
        fake.createStatus = 422
        let url = try await catalog(fake).pullRequest(repo: "o/r", head: "gitstick/alpha", base: "main", title: "T", body: "B")
        XCTAssertNil(url)
    }

    func testNotSignedInIsReportedBeforeAnyRequest() async {
        let fake = FakeGitHub()
        var c = GitHubCatalog(tokens: TokenProvider(explicit: { nil }))
        c.tokens.environment = [:]
        c.tokens.cliLookup = { nil }
        c.transport = { try await fake.transport($0) }
        do {
            _ = try await c.pullRequest(repo: "o/r", head: "h", base: "main", title: "T", body: "B")
            XCTFail("expected notSignedIn")
        } catch GitHubError.notSignedIn {
        } catch { XCTFail("\(error)") }
        XCTAssertTrue(fake.calls.isEmpty)
    }
}

/// The whole chain: protected branch -> divert -> pull request, through the DriveManager.
extension SyncEngineTests {
    func testDivertedWorkGetsAPullRequest() throws {
        let seeded = try mac("seed"); try write(seeded, "seed", "s"); assertIdle(seeded.syncOnce())
        let hook = remote.appendingPathComponent("hooks/pre-receive")
        try """
        #!/bin/sh
        while read old new ref; do
          if [ "$ref" = "refs/heads/main" ]; then echo "remote: error: GH006: Protected branch update failed for refs/heads/main." >&2; exit 1; fi
        done
        exit 0
        """.write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let fake = PullRequestTests.FakeGitHub()
        let m = DriveManager(root: tmp.appendingPathComponent("drives"), stateDir: tmp.appendingPathComponent("state"),
                             tokens: TokenProvider(explicit: { "ghp_test" }))
        m.catalog.transport = { try await fake.transport($0) }
        m.deviceName = "alpha"
        m.identity = ("Sam", "sam@example.com")
        let opened = expectation(description: "pull request")
        let lock = NSLock()
        var result: (String, URL)?
        m.onPullRequest = { id, url in lock.lock(); if result == nil { result = (id, url); opened.fulfill() }; lock.unlock() }

        let drive = try m.plugIn(RemoteDrive(fullName: "o/r", name: "r", owner: "o", isPrivate: false, defaultBranch: "main",
                                             cloneURL: remote.path, canWrite: true, archived: false, sizeKB: 0, pushedAt: nil))
        defer { m.stopAll() }
        try "w".write(to: drive.url.appendingPathComponent("work.txt"), atomically: true, encoding: .utf8)
        m.syncNow("o/r")
        wait(for: [opened], timeout: 30)

        XCTAssertEqual(result?.0, "o/r")
        XCTAssertEqual(result?.1.absoluteString, "https://github.com/o/r/pull/7")
        XCTAssertEqual(m.pullRequest(for: "o/r")?.absoluteString, "https://github.com/o/r/pull/7")
        XCTAssertEqual(fake.calls.map(\.method), ["GET", "POST"])
        XCTAssertEqual(fake.calls[1].body?["head"], "gitstick/alpha")
        XCTAssertEqual(fake.calls[1].body?["base"], "main")
        XCTAssertEqual(fake.calls[1].body?["title"], "Changes from alpha")
        XCTAssertEqual(Git(repo: remote).value(["show", "refs/heads/gitstick/alpha:work.txt"]), "w")

        // The branch is re-pushed every cycle; the same commit doesn't ask GitHub again.
        m.syncNow("o/r")
        let settled = expectation(description: "settled"); DispatchQueue.global().asyncAfter(deadline: .now() + 3) { settled.fulfill() }
        wait(for: [settled], timeout: 10)
        XCTAssertEqual(fake.calls.count, 2)
    }
}
