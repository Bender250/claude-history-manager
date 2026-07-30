import SwiftUI
import AppKit

/// Read-only `NSTextView` in a scroll view.
///
/// SwiftUI's `.textSelection(.enabled)` scopes a selection to a single `Text`,
/// so a drag can never cross two of them — the reason selecting several
/// messages at once is impossible in the composed transcript. One NSTextView
/// holding the whole document is one selection scope, so drag-select, ⌘A and
/// ⌘C span everything in it.
struct SelectableTextView: NSViewRepresentable {
    let text: String
    var font: NSFont = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
    var textColor: NSColor = .labelColor
    var insets: NSSize = NSSize(width: 0, height: 0)

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder

        let tv = NSTextView()
        tv.isEditable = false
        tv.isSelectable = true
        tv.isRichText = false
        tv.drawsBackground = false
        tv.allowsUndo = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        // Wrap to the view's width rather than scrolling sideways.
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width]
        tv.textContainerInset = insets
        tv.usesFindBar = true
        tv.isIncrementalSearchingEnabled = true

        scroll.documentView = tv
        apply(to: tv)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView else { return }
        apply(to: tv)
    }

    private func apply(to tv: NSTextView) {
        tv.font = font
        tv.textColor = textColor
        if tv.string != text {
            tv.string = text
            // A fresh document should start at the top, not wherever the
            // previous session's scroll offset happened to be.
            tv.scroll(NSPoint.zero)
        }
    }
}
