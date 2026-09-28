# CmuxMarkdownUI

Reusable macOS SwiftUI composition for Markdown and text-preview panels. The
package owns rendering composition and pure Markdown support values; the app
supplies panel state and AppKit/WebKit adapters through `MarkdownPanelViewHost`.

The host seam keeps the package independent of the executable target while
preserving the existing app-owned panel model and side effects.

The dependency cuts are deliberately small: `MarkdownPanelViewHost` carries
panel state and actions, `MarkdownPanelAppearance` carries the resolved theme,
and `MarkdownPanelViewAdapters` supplies the app's WebKit renderer, text
editor, search overlay, file header, and focus ring. The package imports only
`CmuxFoundation` and `CmuxSettings`; it never imports the app target.
