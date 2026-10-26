import AppKit
import PDFKit

/// PDFView that reports hover and clicks over text lines to its controller.
final class EditorPDFView: PDFView {
    /// Returns the editable line under a point in page space, if known.
    var lineAt: ((PDFPage, CGPoint) -> EngineLine?)?
    var onHover: ((PDFPage?, EngineLine?) -> Void)?
    var onClickLine: ((PDFPage, EngineLine) -> Void)?

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    private func hit(_ event: NSEvent) -> (PDFPage, EngineLine)? {
        let point = convert(event.locationInWindow, from: nil)
        guard let page = page(for: point, nearest: false) else { return nil }
        let pagePoint = convert(point, to: page)
        guard let line = lineAt?(page, pagePoint) else { return nil }
        return (page, line)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        if let (page, line) = hit(event) {
            onHover?(page, line)
            NSCursor.iBeam.set()
        } else {
            let point = convert(event.locationInWindow, from: nil)
            onHover?(page(for: point, nearest: false), nil)
        }
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHover?(nil, nil)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 1, let (page, line) = hit(event) {
            onClickLine?(page, line)
            return
        }
        super.mouseDown(with: event)
    }
}

/// The text field placed over a line while it is being edited.
final class InlineEditor: NSTextField {
    override init(frame: NSRect) {
        super.init(frame: frame)
        isBordered = false
        isBezeled = false
        focusRingType = .none
        drawsBackground = true
        backgroundColor = .white
        textColor = .black
        cell?.isScrollable = true
        cell?.wraps = false
        cell?.usesSingleLineMode = true
        wantsLayer = true
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 2
        layer?.cornerRadius = 3
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
