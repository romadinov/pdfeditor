import AppKit
import PDFKit

final class EditorWindowController: NSWindowController, NSWindowDelegate, NSTextFieldDelegate {
    private let pdfView = EditorPDFView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()

    /// Lines per page index; cleared whenever the PDF changes.
    private var lines: [Int: [EngineLine]] = [:]
    private var loading: Set<Int> = []
    private var generation = 0

    private var hoverAnnotation: PDFAnnotation?
    private var editor: InlineEditor?
    private var editing: (pageIndex: Int, line: EngineLine)?
    private var busy = false
    private var afterEdit: [() -> Void] = []

    private var pdfDocument: Document? { document as? Document }

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 980, height: 860),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.minSize = NSSize(width: 480, height: 360)
        super.init(window: window)
        window.delegate = self
        buildLayout(in: window)
        window.center()
        window.setFrameAutosaveName("EditorWindow")
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override var document: AnyObject? {
        didSet {
            pdfDocument?.onContentChange = { [weak self] in self?.reloadPDF() }
            reloadPDF()
        }
    }

    // MARK: - Layout

    private func buildLayout(in window: NSWindow) {
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.displaysPageBreaks = true
        pdfView.backgroundColor = .underPageBackgroundColor
        pdfView.lineAt = { [weak self] page, point in self?.line(at: point, on: page) }
        pdfView.onHover = { [weak self] page, line in self?.hover(page: page, line: line) }
        pdfView.onClickLine = { [weak self] page, line in self?.beginEditing(line, on: page) }

        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.maximumNumberOfLines = 2
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let bar = NSStackView(views: [spinner, statusLabel])
        bar.orientation = .horizontal
        bar.spacing = 6
        bar.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)

        let content = NSView()
        let divider = NSBox()
        divider.boxType = .separator
        for view in [pdfView, divider, bar] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            pdfView.topAnchor.constraint(equalTo: content.topAnchor),
            pdfView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            pdfView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            divider.topAnchor.constraint(equalTo: pdfView.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: divider.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            bar.heightAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
        window.contentView = content

        NotificationCenter.default.addObserver(self, selector: #selector(viewChanged),
                                               name: .PDFViewScaleChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: .PDFViewPageChanged, object: pdfView)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: NSView.boundsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(pageChanged),
                                               name: NSWindow.didBecomeKeyNotification, object: window)
        EngineClient.shared.onSetupProgress = { [weak self] message in
            self?.setBusy(message != nil)
            if let message { self?.setStatus(message) } else { self?.showHint() }
        }
        showHint()
    }

    // MARK: - Loading

    /// Show the document's current bytes, keeping the zoom and scroll position.
    private func reloadPDF() {
        guard let data = pdfDocument?.pdfData, let newPDF = PDFDocument(data: data) else { return }
        finishEditing(commit: false)
        let scrollView = pdfView.documentView?.enclosingScrollView
        let origin = scrollView?.contentView.bounds.origin
        let autoScales = pdfView.autoScales
        let scale = pdfView.scaleFactor
        let hadDocument = pdfView.document != nil

        hoverAnnotation = nil
        lines.removeAll()
        loading.removeAll()
        generation += 1
        pdfView.document = newPDF

        if hadDocument, let scrollView, let origin {
            pdfView.autoScales = autoScales
            if !autoScales { pdfView.scaleFactor = scale }
            pdfView.layoutDocumentView()
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
        prefetchVisiblePages()
        // Visible pages are only known once the view has laid out.
        DispatchQueue.main.async { [weak self] in self?.prefetchVisiblePages() }
    }

    private func loadLines(for pageIndex: Int) {
        guard lines[pageIndex] == nil, !loading.contains(pageIndex), let doc = pdfDocument else { return }
        loading.insert(pageIndex)
        let requestGeneration = generation
        EngineClient.shared.lines(in: doc.workingFile, page: pageIndex) { [weak self] result in
            guard let self, requestGeneration == self.generation else { return }
            self.loading.remove(pageIndex)
            switch result {
            case .success(let found):
                self.lines[pageIndex] = found
            case .failure(let error):
                self.setStatus("Couldn’t read the text on this page: \(error.localizedDescription)", warning: true)
            }
        }
    }

    private func prefetchVisiblePages() {
        guard let pdf = pdfView.document else { return }
        for page in pdfView.visiblePages {
            loadLines(for: pdf.index(for: page))
        }
        if let page = pdfView.currentPage {
            loadLines(for: pdf.index(for: page))
        }
    }

    @objc private func pageChanged(_ notification: Notification) {
        // Bounds changes come from every view; only scrolling of this PDF matters.
        if notification.name == NSView.boundsDidChangeNotification,
           (notification.object as? NSView) !== pdfView.documentView?.enclosingScrollView?.contentView {
            return
        }
        prefetchVisiblePages()
    }

    @objc private func viewChanged() {
        // The inline editor is sized for the old zoom level.
        finishEditing(commit: true)
    }

    // MARK: - Hit testing and hover

    private func line(at point: CGPoint, on page: PDFPage) -> EngineLine? {
        guard let pdf = pdfView.document else { return nil }
        let index = pdf.index(for: page)
        guard let pageLines = lines[index] else {
            loadLines(for: index)
            return nil
        }
        return pageLines
            .filter { $0.editable && $0.textBounds.insetBy(dx: -1.5, dy: -1.5).contains(point) }
            .min { $0.textBounds.width * $0.textBounds.height < $1.textBounds.width * $1.textBounds.height }
    }

    private func hover(page: PDFPage?, line: EngineLine?) {
        if let hoverAnnotation {
            hoverAnnotation.page?.removeAnnotation(hoverAnnotation)
            self.hoverAnnotation = nil
        }
        guard !busy, editing == nil, let page, let line else { return }
        let box = PDFAnnotation(bounds: line.textBounds.insetBy(dx: -2, dy: -2), forType: .square, withProperties: nil)
        box.color = NSColor.controlAccentColor.withAlphaComponent(0.8)
        box.interiorColor = NSColor.controlAccentColor.withAlphaComponent(0.08)
        let border = PDFBorder()
        border.lineWidth = 1
        box.border = border
        page.addAnnotation(box)
        hoverAnnotation = box
        setStatus("\(line.font) · \(formatSize(line.size)) pt — click to edit")
    }

    // MARK: - Inline editing

    private func beginEditing(_ line: EngineLine, on page: PDFPage) {
        guard !busy, let pdf = pdfView.document, let documentView = pdfView.documentView else { return }
        finishEditing(commit: true)
        hover(page: nil, line: nil)

        // The editor lives in the document view. Depending on the PDFKit
        // version that view is either drawn at the zoom level or magnified by
        // its scroll view, so measure everything in its own units: `unit` is
        // document-view units per PDF point, `pixel` per on-screen point.
        let lineRect = line.textBounds
        var frame = pdfView.convert(pdfView.convert(lineRect, from: page), to: documentView)
        let unit = frame.height / max(lineRect.height, 0.01)
        let pixel = unit / max(pdfView.scaleFactor, 0.01)
        let font = NSFont(name: line.font.replacingOccurrences(of: " ", with: "-"), size: line.size * unit)
            ?? NSFont(name: line.font, size: line.size * unit)
            ?? NSFont.systemFont(ofSize: line.size * unit)
        let pageRight = pdfView.convert(pdfView.convert(page.bounds(for: pdfView.displayBox), from: page),
                                        to: documentView).maxX
        let field = InlineEditor(frame: .zero)
        field.layer?.borderWidth = 2 * pixel
        field.layer?.cornerRadius = 3 * pixel
        field.font = font
        field.stringValue = line.displayText

        // A text field insets its text from the top by roughly half a line,
        // so it needs about 1.8x the font size to show the text unclipped.
        let height = max(frame.height, font.pointSize * 1.8)
        frame.origin.y -= (height - frame.height) / 2
        frame.size.height = height
        frame.origin.x -= 4 * pixel
        frame.size.width = min(max(frame.width + 60 * unit, 140 * pixel), pageRight - frame.minX)
        field.frame = frame
        field.delegate = self
        documentView.addSubview(field)
        editor = field
        editing = (pdf.index(for: page), line)
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
        setStatus("Editing “\(line.font)” \(formatSize(line.size)) pt — Return to apply, Esc to cancel")
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            finishEditing(commit: false)
            return true
        case #selector(NSResponder.insertNewline(_:)):
            finishEditing(commit: true)
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        finishEditing(commit: true)
    }

    private func finishEditing(commit: Bool) {
        guard let field = editor, let (pageIndex, line) = editing else { return }
        editor = nil
        editing = nil
        let newText = field.stringValue
        field.delegate = nil
        field.removeFromSuperview()
        window?.makeFirstResponder(pdfView)

        guard commit, newText != line.displayText, let doc = pdfDocument else {
            showHint()
            runAfterEdit()
            return
        }
        setBusy(true)
        setStatus("Updating text…")
        doc.edit(page: pageIndex, line: line, newText: newText) { [weak self] result in
            guard let self else { return }
            self.setBusy(false)
            defer { self.runAfterEdit() }
            switch result {
            case .success(let info):
                self.report(info)
            case .failure(let error):
                self.setStatus("Edit failed.", warning: true)
                self.showError(error)
            }
        }
    }

    /// Apply any edit still open in the inline editor, then run `then` once
    /// the document is up to date (used before saving).
    func commitPendingEdit(then: @escaping () -> Void) {
        afterEdit.append(then)
        if editor != nil {
            finishEditing(commit: true)
        } else if !busy {
            runAfterEdit()
        }
    }

    private func runAfterEdit() {
        guard !busy else { return }
        let pending = afterEdit
        afterEdit.removeAll()
        pending.forEach { $0() }
    }

    // MARK: - Status

    private func report(_ info: EditResult) {
        var message: String
        var warning = false
        switch info.fontSource {
        case .original:
            message = "Updated using the document’s own embedded \(info.font) font."
        case .system:
            message = "Updated in \(info.fontUsed) (installed on this Mac; the PDF only embedded the characters it originally used)."
        case .substitute:
            message = "⚠︎ \(info.font) isn’t installed on this Mac and the PDF doesn’t contain all of the new characters, so \(info.fontUsed) was used. Install \(info.font) and redo the edit for an exact match (⌘Z undoes it)."
            warning = true
        }
        if info.shrunk {
            message += " Text size reduced to \(formatSize(info.size)) pt to fit its box."
        }
        setStatus(message, warning: warning)
    }

    private func showHint() {
        setStatus("Hover over text to see its font, click to edit it. Boxes, lines and shading are never changed.")
    }

    private func setStatus(_ text: String, warning: Bool = false) {
        statusLabel.stringValue = text
        statusLabel.textColor = warning ? .systemOrange : .secondaryLabelColor
    }

    private func setBusy(_ value: Bool) {
        busy = value
        if value { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    private func showError(_ error: Error) {
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.messageText = "The text couldn’t be changed"
        alert.informativeText = error.localizedDescription
        alert.beginSheetModal(for: window)
    }

    private func formatSize(_ size: Double) -> String {
        size.rounded() == size ? String(Int(size)) : String(format: "%.1f", size)
    }

    // MARK: - View menu

    @objc func zoomToActualSize(_ sender: Any?) {
        pdfView.autoScales = false
        pdfView.scaleFactor = 1
    }

    @objc func zoomToFit(_ sender: Any?) {
        pdfView.autoScales = true
    }

    @IBAction func zoomIn(_ sender: Any?) { pdfView.zoomIn(sender) }
    @IBAction func zoomOut(_ sender: Any?) { pdfView.zoomOut(sender) }

    func windowWillClose(_ notification: Notification) {
        NotificationCenter.default.removeObserver(self)
    }
}
