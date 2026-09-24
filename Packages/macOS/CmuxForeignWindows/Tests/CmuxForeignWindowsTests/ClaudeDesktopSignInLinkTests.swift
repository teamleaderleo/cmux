import Foundation
import Testing

@testable import CmuxForeignWindows

@Suite
struct ClaudeDesktopSignInLinkTests {
    private static let googleAuth =
        "claude://login/google-auth?code=4%2F0AVG7fiQ&hop_nonce=6f0c2b7e-9a1d-4c55-8b4e-2f7d1a3c9e10"

    @Test
    func testAcceptsGoogleAuthCallback() throws {
        let link = try ClaudeDesktopSignInLink.parse(Self.googleAuth).get()
        #expect(link.kind == .oauthCallback)
        #expect(link.url.absoluteString == Self.googleAuth)
    }

    @Test(arguments: [
        "claude://claude.ai/magic-link#a1b2c3:dXNlckBleGFtcGxlLmNvbQ==",
        "claude://claude.ai/magic-link?token=abc",
        "claude://claude.ai/login/magic-link?token=abc",
        "CLAUDE://Claude.AI/Magic-Link#abc"
    ])
    func testAcceptsMagicLink(text: String) throws {
        let link = try ClaudeDesktopSignInLink.parse(text).get()
        #expect(link.kind == .magicLink)
    }

    @Test
    func testTrimsSurroundingWhitespace() throws {
        let link = try ClaudeDesktopSignInLink.parse("  \n\t\(Self.googleAuth)\n ").get()
        #expect(link.url.absoluteString == Self.googleAuth)
    }

    @Test(arguments: [
        "https://claude.ai/magic-link#abc",
        "http://login/google-auth?code=x",
        "file:///login/google-auth",
        "claudex://login/google-auth?code=x"
    ])
    func testRejectsWrongScheme(text: String) {
        #expect(ClaudeDesktopSignInLink.parse(text) == .failure(.wrongScheme))
    }

    @Test(arguments: [
        "claude://claude.ai/new",
        "claude://claude.ai/",
        "claude://claude.ai/chat/1234",
        "claude://claude.ai/magic-links",
        "claude://login",
        "claude://login/",
        "claude://evil.example/login/google-auth?code=x",
        "claude://settings/login",
        "claude:login/google-auth",
        "claude://user:pass@login/google-auth?code=x",
        "claude://login:8080/google-auth?code=x"
    ])
    func testRejectsOtherClaudeLinks(text: String) {
        #expect(ClaudeDesktopSignInLink.parse(text) == .failure(.notSignIn))
    }

    @Test(arguments: [
        "not a url",
        "claude://login/google-auth?code=a b",
        "claude://login/google-auth\u{0}",
        "💥",
        "claude://login/google-auth?code=" + String(repeating: "x", count: 9000)
    ])
    func testRejectsGarbage(text: String) {
        #expect(ClaudeDesktopSignInLink.parse(text) == .failure(.malformed))
    }

    @Test(arguments: ["", "   ", "\n\t"])
    func testRejectsEmpty(text: String) {
        #expect(ClaudeDesktopSignInLink.parse(text) == .failure(.empty))
    }
}

@MainActor
@Suite
struct ClaudeDesktopSignInLinkDeliveryTests {
    private struct SendError: Error {}

    @Test
    func testSendsValidLinkToPaneProcessOnly() {
        var sent: [(String, pid_t)] = []
        let outcome = ClaudeDesktopSignInLinkDelivery.deliver(
            text: " claude://login/google-auth?code=c&hop_nonce=n ",
            to: 321
        ) { url, pid in
            sent.append((url.absoluteString, pid))
        }
        #expect(outcome == .sent(321))
        #expect(sent.count == 1)
        #expect(sent.first?.0 == "claude://login/google-auth?code=c&hop_nonce=n")
        #expect(sent.first?.1 == 321)
    }

    @Test
    func testInvalidLinkNeverSends() {
        var sendCount = 0
        let outcome = ClaudeDesktopSignInLinkDelivery.deliver(
            text: "claude://claude.ai/new",
            to: 321
        ) { _, _ in
            sendCount += 1
        }
        #expect(outcome == .notSignInLink(.notSignIn))
        #expect(sendCount == 0)
    }

    @Test
    func testMissingPasteboardTextIsEmpty() {
        let outcome = ClaudeDesktopSignInLinkDelivery.deliver(text: nil, to: 321) { _, _ in }
        #expect(outcome == .notSignInLink(.empty))
    }

    @Test
    func testNoProcessMeansNotRunning() {
        var sendCount = 0
        let outcome = ClaudeDesktopSignInLinkDelivery.deliver(
            text: "claude://claude.ai/magic-link#abc",
            to: nil
        ) { _, _ in
            sendCount += 1
        }
        #expect(outcome == .claudeNotRunning)
        #expect(sendCount == 0)
    }

    @Test
    func testSendErrorIsReported() {
        let outcome = ClaudeDesktopSignInLinkDelivery.deliver(
            text: "claude://claude.ai/magic-link#abc",
            to: 321
        ) { _, _ in
            throw SendError()
        }
        guard case .sendFailed = outcome else {
            Issue.record("expected sendFailed, got \(outcome)")
            return
        }
    }
}
