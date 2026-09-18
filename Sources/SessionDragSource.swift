import SwiftUI

/// Places one native drag source over one rendered Vault session row.
struct SessionDragSource: NSViewRepresentable {
    let entry: SessionEntry
    let beginDrag: SessionDragBeginAction
    let onDoubleClick: @MainActor () -> Void
    var activatesOnSingleClick = false

    func makeNSView(context: Context) -> SessionDragSourceView {
        let view = SessionDragSourceView(
            entry: entry,
            beginDrag: beginDrag,
            onDoubleClick: onDoubleClick
        )
        view.activatesOnSingleClick = activatesOnSingleClick
        return view
    }

    func updateNSView(_ nsView: SessionDragSourceView, context: Context) {
        nsView.activatesOnSingleClick = activatesOnSingleClick
        nsView.update(
            entry: entry,
            beginDrag: beginDrag,
            onDoubleClick: onDoubleClick
        )
    }
}
