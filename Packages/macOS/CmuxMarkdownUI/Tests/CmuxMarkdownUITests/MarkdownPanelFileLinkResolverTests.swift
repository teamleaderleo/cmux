import Testing
@testable import CmuxMarkdownUI

struct MarkdownPanelFileLinkResolverTests {
    @Test func recognizesMarkdownExtensions() {
        let resolver = MarkdownPanelFileLinkResolver()
        #expect(resolver.isMarkdownPathLike("README.md"))
        #expect(resolver.isMarkdownPathLike("notes.MARKDOWN"))
        #expect(!resolver.isMarkdownPathLike("image.png"))
    }
}
