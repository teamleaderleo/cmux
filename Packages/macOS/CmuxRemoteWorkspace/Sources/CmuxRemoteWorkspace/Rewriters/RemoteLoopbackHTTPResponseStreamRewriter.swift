import Foundation

struct RemoteLoopbackHTTPResponseStreamRewriter: Sendable {
    static let maxHeaderBytes = 64 * 1024
    private static let headerDelimiter = Data([0x0d, 0x0a, 0x0d, 0x0a])

    private let aliasHost: String
    private var pendingHeaderBytes = Data()
    private var hasForwardedHeaders = false

    init(aliasHost: String) {
        self.aliasHost = aliasHost
    }

    mutating func rewriteNextChunk(_ data: Data, eof: Bool) -> Data {
        guard !hasForwardedHeaders else { return data }

        if !data.isEmpty {
            pendingHeaderBytes.append(data)
        }

        let hasHeaderDelimiter = pendingHeaderBytes.range(of: Self.headerDelimiter) != nil
        if !hasHeaderDelimiter,
           pendingHeaderBytes.count <= Self.maxHeaderBytes,
           !eof {
            return Data()
        }

        hasForwardedHeaders = true
        let payload = pendingHeaderBytes
        pendingHeaderBytes = Data()

        guard hasHeaderDelimiter else {
            // Oversized or EOF-terminated incomplete response headers pass
            // through unchanged. The important invariant here is bounded
            // buffering; once the limit is crossed, later chunks stream.
            return payload
        }
        return RemoteLoopbackHTTPResponseRewriter.rewriteIfNeeded(
            data: payload,
            aliasHost: aliasHost
        )
    }
}
