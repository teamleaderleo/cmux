import Foundation
import Testing
import CmuxCore
@testable import CmuxRemoteWorkspace

@Suite("Remote proxy output budget")
struct RemoteProxyOutputBudgetTests {
    @Test("reservations enforce byte and send ceilings and release idempotently")
    func reservationsAreBoundedAndReleased() throws {
        let budget = RemoteProxyOutputBudget(maxPendingBytes: 10, maxPendingSends: 2)
        let first = try #require(budget.reserve(bytes: 4))
        let second = try #require(budget.reserve(bytes: 6))
        #expect(budget.snapshot() == .init(pendingBytes: 10, pendingSends: 2))
        #expect(budget.reserve(bytes: 0) == nil)
        #expect(budget.reserve(bytes: 1) == nil)

        first.release()
        first.release()
        #expect(budget.snapshot() == .init(pendingBytes: 6, pendingSends: 1))
        let third = try #require(budget.reserve(bytes: 4))
        #expect(budget.snapshot() == .init(pendingBytes: 10, pendingSends: 2))

        second.release()
        third.release()
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingSends: 0))
    }

    @Test("reservation deinit returns capacity")
    func reservationDeinitReturnsCapacity() throws {
        let budget = RemoteProxyOutputBudget(maxPendingBytes: 8, maxPendingSends: 1)
        var reservation: RemoteProxyOutputReservation? = try #require(budget.reserve(bytes: 8))
        #expect(budget.snapshot() == .init(pendingBytes: 8, pendingSends: 1))
        reservation = nil
        #expect(budget.snapshot() == .init(pendingBytes: 0, pendingSends: 0))
    }
}

@Suite("Remote loopback HTTP response stream rewriter")
struct RemoteLoopbackHTTPResponseStreamRewriterTests {
    @Test("buffers a split response header, rewrites once, and streams later bytes")
    func splitHeaderRewritesOnce() {
        let alias = RemoteLoopbackProxyAlias.aliasHost
        var rewriter = RemoteLoopbackHTTPResponseStreamRewriter(aliasHost: alias)
        let first = Data("HTTP/1.1 302 Found\r\nLocation: http://local".utf8)
        #expect(rewriter.rewriteNextChunk(first, eof: false).isEmpty)
        let second = Data("host:3000/next\r\n\r\nBODY".utf8)
        let flushed = rewriter.rewriteNextChunk(second, eof: false)
        let text = String(decoding: flushed, as: UTF8.self)
        #expect(text.contains("Location: http://\(alias):3000/next"))
        #expect(text.hasSuffix("\r\n\r\nBODY"))

        let later = Data("later".utf8)
        #expect(rewriter.rewriteNextChunk(later, eof: false) == later)
    }

    @Test("EOF flushes an incomplete response header even when the EOF chunk is empty")
    func eofFlushesBufferedIncompleteHeader() {
        let alias = RemoteLoopbackProxyAlias.aliasHost
        var rewriter = RemoteLoopbackHTTPResponseStreamRewriter(aliasHost: alias)
        let partial = Data("HTTP/1.1 200 OK\r\nX-Test: value\r\n".utf8)
        #expect(rewriter.rewriteNextChunk(partial, eof: false).isEmpty)
        #expect(rewriter.rewriteNextChunk(Data(), eof: true) == partial)
    }

    @Test("oversized unterminated response headers stop buffering at the explicit ceiling")
    func oversizedHeaderStopsBuffering() {
        let alias = RemoteLoopbackProxyAlias.aliasHost
        var rewriter = RemoteLoopbackHTTPResponseStreamRewriter(aliasHost: alias)
        let oversized = Data(
            ("HTTP/1.1 200 OK\r\nX-Test: " + String(repeating: "x", count: 65 * 1024)).utf8
        )
        #expect(rewriter.rewriteNextChunk(oversized, eof: false) == oversized)
        let later = Data("later".utf8)
        #expect(rewriter.rewriteNextChunk(later, eof: false) == later)
    }
}
