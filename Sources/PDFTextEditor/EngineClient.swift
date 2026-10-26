import Foundation

/// A line of text on a page, as reported by the engine. `rect` is in PDF user
/// space, which is also PDFKit's page coordinate space.
struct EngineLine: Decodable {
    let id: String
    let text: String
    let rect: [Double]
    /// Bounds of the visible characters, excluding spaces used for layout.
    let textRect: [Double]
    let font: String
    let size: Double
    let color: String
    let editable: Bool

    var bounds: CGRect { Self.cgRect(rect) }
    var textBounds: CGRect { Self.cgRect(textRect) }

    /// The text as shown for editing, without leading/trailing layout spaces.
    var displayText: String { text.trimmingCharacters(in: .whitespaces) }

    private static func cgRect(_ r: [Double]) -> CGRect {
        CGRect(x: r[0], y: r[1], width: r[2] - r[0], height: r[3] - r[1])
    }
}

/// How an edit was rendered, so the UI can say whether the font was preserved.
struct EditResult: Decodable {
    enum FontSource: String, Decodable {
        case original, system, substitute
    }
    let font: String
    let fontUsed: String
    let fontSource: FontSource
    let size: Double
    let shrunk: Bool
}

private struct EngineStatus: Decodable {
    let ok: Bool
    let error: String?
}

struct EngineError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Talks to the Python text engine (`pdftext_engine.py`) over stdin/stdout,
/// one JSON object per line. Requests are serialised on a private queue and
/// completions are delivered on the main queue.
final class EngineClient: @unchecked Sendable {
    static let shared = EngineClient()

    /// Called on the main queue while the one-time Python setup runs.
    var onSetupProgress: ((String?) -> Void)?

    private let queue = DispatchQueue(label: "PDFTextEditor.engine")
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var buffer = Data()
    private var stderrLog = Data()
    private let stderrLock = NSLock()

    static var supportDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PDFTextEditor", isDirectory: true)
    }
    static var venvPython: URL {
        supportDirectory.appendingPathComponent("venv/bin/python3")
    }

    func warmUp() {
        queue.async { try? self.ensureRunning() }
    }

    func lines(in file: URL, page: Int, completion: @escaping (Result<[EngineLine], Error>) -> Void) {
        struct Reply: Decodable { let lines: [EngineLine] }
        send(["cmd": "lines", "path": file.path, "page": page], as: Reply.self) {
            completion($0.map(\.lines))
        }
    }

    func edit(file: URL, output: URL, page: Int, line: EngineLine, text: String,
              completion: @escaping (Result<EditResult, Error>) -> Void) {
        send(["cmd": "edit", "path": file.path, "out": output.path, "page": page,
              "line": line.id, "expect": line.text, "text": text],
             as: EditResult.self, completion: completion)
    }

    // MARK: - Transport

    private func send<T: Decodable>(_ request: [String: Any], as type: T.Type,
                                    completion: @escaping (Result<T, Error>) -> Void) {
        queue.async {
            let result: Result<T, Error> = Result { try self.roundTrip(request) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func roundTrip<T: Decodable>(_ request: [String: Any]) throws -> T {
        try ensureRunning()
        var payload = try JSONSerialization.data(withJSONObject: request)
        payload.append(0x0A)
        do {
            try input?.write(contentsOf: payload)
        } catch {
            stop()
            throw EngineError(message: "The text engine stopped unexpectedly. Please try again.\n\(recentErrors())")
        }
        let line = try readLine()
        let status = try JSONDecoder().decode(EngineStatus.self, from: line)
        guard status.ok else { throw EngineError(message: status.error ?? "Unknown engine error") }
        return try JSONDecoder().decode(T.self, from: line)
    }

    private func readLine() throws -> Data {
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                return Data(line)
            }
            guard let chunk = output?.availableData, !chunk.isEmpty else {
                stop()
                throw EngineError(message: "The text engine stopped unexpectedly. Please try again.\n\(recentErrors())")
            }
            buffer.append(chunk)
        }
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        try ensureEnvironment()
        guard let script = Bundle.main.url(forResource: "pdftext_engine", withExtension: "py") else {
            throw EngineError(message: "pdftext_engine.py is missing from the app bundle.")
        }
        let p = Process()
        p.executableURL = Self.venvPython
        p.arguments = ["-u", script.path]
        let inPipe = Pipe(), outPipe = Pipe(), errPipe = Pipe()
        p.standardInput = inPipe
        p.standardOutput = outPipe
        p.standardError = errPipe
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard let self, !data.isEmpty else { return }
            self.stderrLock.lock()
            self.stderrLog.append(data)
            if self.stderrLog.count > 8000 { self.stderrLog = self.stderrLog.suffix(4000) }
            self.stderrLock.unlock()
        }
        try p.run()
        process = p
        input = inPipe.fileHandleForWriting
        output = outPipe.fileHandleForReading
        buffer.removeAll()
    }

    private func stop() {
        process?.terminate()
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
    }

    private func recentErrors() -> String {
        stderrLock.lock(); defer { stderrLock.unlock() }
        return String(decoding: stderrLog.suffix(1500), as: UTF8.self)
    }

    // MARK: - One-time Python setup

    /// Creates a private Python environment with PyMuPDF and fontTools the
    /// first time the app runs (or if it has been deleted).
    private func ensureEnvironment() throws {
        if canImportDependencies() { return }
        report("Setting up the text engine (one-time, about a minute)…")
        defer { report(nil) }
        try FileManager.default.createDirectory(at: Self.supportDirectory, withIntermediateDirectories: true)
        let venv = Self.supportDirectory.appendingPathComponent("venv")
        if !FileManager.default.fileExists(atPath: Self.venvPython.path) {
            guard let base = Self.basePython() else {
                throw EngineError(message: "Python 3 was not found. Install it with “brew install python” or from python.org, then try again.")
            }
            try run(base, ["-m", "venv", venv.path])
        }
        let pip = venv.appendingPathComponent("bin/pip")
        try run(pip, ["install", "--disable-pip-version-check", "-q", "pymupdf", "fonttools"])
        guard canImportDependencies() else {
            throw EngineError(message: "Could not install PyMuPDF and fontTools into \(venv.path).")
        }
    }

    private func canImportDependencies() -> Bool {
        guard FileManager.default.isExecutableFile(atPath: Self.venvPython.path) else { return false }
        return (try? run(Self.venvPython, ["-c", "import pymupdf, fontTools"])) != nil
    }

    private static func basePython() -> URL? {
        ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .map(URL.init(fileURLWithPath:))
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    @discardableResult
    private func run(_ tool: URL, _ args: [String]) throws -> String {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard p.terminationStatus == 0 else {
            throw EngineError(message: "\(tool.lastPathComponent) failed:\n\(text.suffix(1500))")
        }
        return text
    }

    private func report(_ message: String?) {
        DispatchQueue.main.async { self.onSetupProgress?(message) }
    }
}
