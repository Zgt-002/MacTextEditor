import AppKit

final class ArrowCursorScroller: NSScroller {
    override func resetCursorRects() {
        discardCursorRects()
        addCursorRect(bounds, cursor: .arrow)
    }

    override func mouseDown(with event: NSEvent) {
        NSCursor.arrow.set()
        super.mouseDown(with: event)
        NSCursor.arrow.set()
    }
}
