import XCTest
@testable import GitstickCore

/// What never leaves the Mac. A wrong auto-commit is public and permanent; a held-back file is a
/// yellow line in the menu. So the net is wide, and the test says exactly how wide.
final class GatekeeperTests: XCTestCase {
    var root: URL!
    let gk = Gatekeeper()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("gitstick-gk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func check(_ path: String, _ content: String = "plain text\n") throws -> HoldReason? {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: url, atomically: true, encoding: .utf8)
        return gk.check(path: path, root: root)
    }

    func testSecretFileNames() throws {
        for name in [".env", ".env.local", ".env.production", ".envrc", ".npmrc", ".netrc", ".htpasswd", ".pgpass",
                     ".git-credentials", "id_rsa", "id_ed25519", "id_ed25519.pub", "credentials", "secrets.yml",
                     "token.json", "kubeconfig", "client_secret_123-abc.apps.googleusercontent.com.json",
                     "deploy/service-account.json"] {
            XCTAssertEqual(try check(name), .looksLikeSecret("file name"), name)
        }
        for name in [".env.example", ".env.sample", ".env.template", "environment.md", "credentials.md", "token.swift"] {
            XCTAssertNil(try check(name), name)
        }
    }

    func testSecretExtensionsAndFolders() throws {
        for name in ["server.pem", "tls.key", "cert.p12", "AuthKey_ABC123.p8", "putty.ppk", "vault.kdbx",
                     "login.keychain", "infra/terraform.tfstate", "vpn/office.ovpn"] {
            if case .looksLikeSecret? = try check(name) {} else { XCTFail(name) }
        }
        for path in [".ssh/config", ".aws/config", "home/.gnupg/pubring.kbx", ".kube/anything"] {
            if case .looksLikeSecret(let why)? = try check(path) { XCTAssertTrue(why.hasPrefix("inside"), why) }
            else { XCTFail(path) }
        }
        XCTAssertNil(try check("docs/ssh-howto.md"))
        XCTAssertNil(try check("cert.crt"))       // public half: fine to share
    }

    func testSecretContent() throws {
        let hits: [(String, String)] = [
            ("-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n", "private key"),
            ("-----BEGIN PGP PRIVATE KEY BLOCK-----\nabc\n", "private key"),
            ("token = 'ghp_" + String(repeating: "a", count: 36) + "'", "GitHub token"),
            ("github_pat_" + String(repeating: "b", count: 60), "GitHub token"),
            ("aws_access_key_id = AKIAIOSFODNN7EXAMPLE", "AWS access key"),
            ("AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY1", "AWS secret key"),
            ("xoxb-12345678901-abcdefghij", "Slack token"),
            ("https://hooks.slack.com/services/T0000/B0000/XXXXXXXX", "Slack webhook"),
            ("sk-ant-api03-" + String(repeating: "c", count: 40), "Anthropic API key"),
            ("OPENAI_API_KEY=sk-proj-" + String(repeating: "d", count: 20) + "T3BlbkFJ" + String(repeating: "e", count: 20), "OpenAI API key"),
            ("key: AIzaSyA" + String(repeating: "f", count: 32), "Google API key"),
            ("sk_live_" + String(repeating: "g", count: 24), "Stripe key"),
            ("//registry.npmjs.org/:_authToken=npm_" + String(repeating: "h", count: 36), "npm token"),
            ("pypi-AgEIcHlwaS5vcmc" + String(repeating: "i", count: 60), "PyPI token"),
            ("HF_TOKEN=hf_" + String(repeating: "j", count: 34), "Hugging Face token"),
            ("SG." + String(repeating: "k", count: 22) + "." + String(repeating: "l", count: 43), "SendGrid key"),
            ("glpat-" + String(repeating: "m", count: 20), "GitLab token"),
        ]
        for (i, (content, label)) in hits.enumerated() {
            XCTAssertEqual(try check("f\(i).txt", content), .looksLikeSecret(label), content)
        }
        for ok in ["const key = process.env.API_KEY", "-----BEGIN CERTIFICATE-----\nabc\n", "skip-this-T3BlbkFJ",
                   "aws_secret_access_key = <your key here>", "sk_test_" + String(repeating: "n", count: 24)] {
            XCTAssertNil(try check("ok.txt", ok), ok)
        }
    }

    func testBinariesAndBigFilesAreNotScannedForText() throws {
        var gk = Gatekeeper()
        gk.maxFileBytes = 100
        let url = root.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 101).write(to: url)
        XCTAssertEqual(gk.check(path: "big.bin", root: root), .tooLarge(bytes: 101))
        try (Data([0, 1, 2]) + Data("ghp_".utf8) + Data(repeating: 0x61, count: 36)).write(to: url.deletingLastPathComponent().appendingPathComponent("img.bin"))
        XCTAssertNil(gk.check(path: "img.bin", root: root))
    }
}
