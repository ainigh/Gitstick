import XCTest
@testable import GitstickCore

/// How the app knows there's a newer Gitstick on GitHub.
final class ReleaseTests: XCTestCase {
    func testVersionsCompareNumberByNumber() {
        XCTAssertLessThan(Version("0.3.9")!, Version("0.3.12")!)
        XCTAssertLessThan(Version("v0.3")!, Version("0.3.1")!)
        XCTAssertEqual(Version("v1.2.0")!, Version("1.2")!)
        XCTAssertNil(Version("dev"))
        XCTAssertNil(Version("0.3.0-dev"))
    }

    func testDecodesGitHubsAnswer() throws {
        let json = """
        {"tag_name": "v0.3.14", "target_commitish": "abc123", "body": "Faster\\n\\nDetails", "html_url": "https://github.com/o/r/releases/tag/v0.3.14",
         "assets": [{"name": "Gitstick.zip", "browser_download_url": "https://github.com/o/r/releases/download/v0.3.14/Gitstick.zip",
                     "url": "https://api.github.com/repos/o/r/releases/assets/1", "size": 1}]}
        """
        let r = try Release.decode(Data(json.utf8))
        XCTAssertEqual(r.version, Version("0.3.14"))
        XCTAssertEqual(r.title, "Faster")
        XCTAssertEqual(r.asset(named: "Gitstick.zip")?.browserDownloadURL.lastPathComponent, "Gitstick.zip")
        XCTAssertEqual(r.asset(named: "Gitstick.zip")?.apiURL.lastPathComponent, "1")
        XCTAssertEqual(r.target, "abc123")
    }

    func testOnlyNewerReleasesAreOffered() throws {
        let r = try Release.decode(Data(#"{"tag_name": "v0.3.14", "assets": []}"#.utf8))
        XCTAssertTrue(r.isNewer(than: "0.3.9"))
        XCTAssertTrue(r.isNewer(than: "0.0.0"))          // a local make-app.sh build
        XCTAssertFalse(r.isNewer(than: "0.3.14"))
        XCTAssertFalse(r.isNewer(than: "0.4.0"))
        XCTAssertFalse(r.isNewer(than: "dev"))            // swift run: no bundle, no updates
    }
}
