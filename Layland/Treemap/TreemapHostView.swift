import SwiftUI

struct TreemapHostView: NSViewRepresentable {
    let tree: FileTree
    let configuration: TreemapView.Configuration
    let selection: Int32?
    let highlightedNodes: [Int32]?
    /// Incremented by the session to toggle Quick Look from the menu.
    let quickLookRequest: Int
    let onHover: (Int32?) -> Void
    let onSelect: (Int32?) -> Void
    let onOpen: (Int32) -> Void
    var onRender: () -> Void = {}
    var onDelete: (Int32) -> Void = { _ in }
    var isLocked: (Int32) -> Bool = { _ in false }
    var onLocked: (Int32) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> TreemapView {
        let view = TreemapView()
        view.onHover = onHover
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.onRender = onRender
        view.onDelete = onDelete
        view.isLocked = isLocked
        view.onLocked = onLocked
        context.coordinator.quickLookRequest = quickLookRequest
        return view
    }

    func updateNSView(_ view: TreemapView, context: Context) {
        view.onHover = onHover
        view.onSelect = onSelect
        view.onOpen = onOpen
        view.onRender = onRender
        view.onDelete = onDelete
        view.isLocked = isLocked
        view.onLocked = onLocked
        view.configure(tree: tree, configuration)
        view.selection = selection
        view.highlightedNodes = highlightedNodes
        if context.coordinator.quickLookRequest != quickLookRequest {
            context.coordinator.quickLookRequest = quickLookRequest
            view.toggleQuickLook()
        }
    }

    @MainActor
    final class Coordinator {
        var quickLookRequest = 0
    }
}
