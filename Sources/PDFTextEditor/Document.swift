import AppKit
import PDFKit

/// A PDF being edited. The bytes live in memory (for saving and undo) and are
/// mirrored to a private working file that the text engine reads.
@objc(Document)
final class Document: NSDocument {
    private(set) var pdfData = Data()
    private let workDirectory: URL
    let workingFile: URL

    /// Called whenever the PDF content changes (edit, undo, redo, revert).
    var onContentChange: (() -> Void)?

    override init() {
        workDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("PDFTextEditor-\(UUID().uuidString)", isDirectory: true)
        workingFile = workDirectory.appendingPathComponent("working.pdf")
        try? FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        super.init()
    }

    // Classic save model: changes are only written when you choose Save.
    override class var autosavesInPlace: Bool { false }

    override func makeWindowControllers() {
        addWindowController(EditorWindowController())
    }

    override func read(from data: Data, ofType typeName: String) throws {
        guard let pdf = PDFDocument(data: data) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if pdf.isEncrypted && pdf.isLocked {
            throw EngineError(message: "This PDF is password protected. Remove the password before editing.")
        }
        try store(data)
    }

    // Saving first applies an edit still open in the inline editor.
    override func save(_ sender: Any?) {
        commitPendingEdits { super.save(sender) }
    }

    override func saveAs(_ sender: Any?) {
        commitPendingEdits { super.saveAs(sender) }
    }

    private func commitPendingEdits(then: @escaping () -> Void) {
        let editors = windowControllers.compactMap { $0 as? EditorWindowController }
        guard let first = editors.first else { return then() }
        first.commitPendingEdit(then: then)
    }

    override func data(ofType typeName: String) throws -> Data {
        pdfData
    }

    override func revert(toContentsOf url: URL, ofType typeName: String) throws {
        try super.revert(toContentsOf: url, ofType: typeName)
        undoManager?.removeAllActions()
    }

    override func close() {
        super.close()
        try? FileManager.default.removeItem(at: workDirectory)
    }

    /// Replace the text of one line. The change is undoable.
    func edit(page: Int, line: EngineLine, newText: String,
              completion: @escaping (Result<EditResult, Error>) -> Void) {
        let output = workDirectory.appendingPathComponent("edit-\(UUID().uuidString).pdf")
        EngineClient.shared.edit(file: workingFile, output: output, page: page, line: line, text: newText) { result in
            defer { try? FileManager.default.removeItem(at: output) }
            completion(result.flatMap { info in
                Result {
                    try self.replaceContent(with: Data(contentsOf: output), actionName: "Edit Text")
                    return info
                }
            })
        }
    }

    private func replaceContent(with data: Data, actionName: String) throws {
        let previous = pdfData
        try store(data)
        undoManager?.registerUndo(withTarget: self) { doc in
            try? doc.replaceContent(with: previous, actionName: actionName)
        }
        undoManager?.setActionName(actionName)
    }

    private func store(_ data: Data) throws {
        try data.write(to: workingFile, options: .atomic)
        pdfData = data
        onContentChange?()
    }
}
