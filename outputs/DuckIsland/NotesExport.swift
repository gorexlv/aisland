import Cocoa
import Darwin

func htmlEscape(_ value: String) -> String {
    value.replacingOccurrences(of: "&", with: "&amp;")
        .replacingOccurrences(of: "<", with: "&lt;")
        .replacingOccurrences(of: ">", with: "&gt;")
        .replacingOccurrences(of: "\"", with: "&quot;")
}
func scriptLiteral(_ value: String) -> String {
    "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")
        .replacingOccurrences(of: "\r", with: "\\r")
        .replacingOccurrences(of: "\n", with: "\\n") + "\""
}
func notesScript(title: String, text: String, existingID: String? = nil) -> String {
    let html = "<h1>" + htmlEscape(title) + "</h1><div>" + htmlEscape(text).replacingOccurrences(of: "\n", with: "<br>") + "</div>"
    let operation: String
    if let existingID {
        operation = "set meetingNote to note id " + scriptLiteral(existingID) + "\nset body of meetingNote to " + scriptLiteral(html)
    } else {
        operation = "set meetingNote to make new note at destination with properties {name:" + scriptLiteral(title) + ", body:" + scriptLiteral(html) + "}"
    }
    return """
    tell application "Notes"
        set destination to default folder of default account
        \(operation)
        return {id of meetingNote, name of meetingNote, name of container of meetingNote}
    end tell
    """
}
struct NotesFailure: LocalizedError {
    let detail: String
    var errorDescription: String? { detail }
}
struct NoteReceipt: Codable {
    let id: String
    let name: String
    let folder: String
}
func insertIntoNotes(title: String, text: String, existingID: String? = nil) throws -> NoteReceipt {
    guard let script = NSAppleScript(source: notesScript(title: title, text: text, existingID: existingID)) else {
        throw NotesFailure(detail: "无法创建备忘录脚本")
    }
    var error: NSDictionary?
    let result = script.executeAndReturnError(&error)
    if let error {
        let code = error[NSAppleScript.errorNumber] as? Int ?? 0
        if code == -1743 {
            throw NotesFailure(detail: "请在系统设置 → 隐私与安全性 → 自动化中，允许 Duck Island 控制备忘录，再点“写入备忘录”。")
        }
        throw NotesFailure(detail: "备忘录写入失败：\(error[NSAppleScript.errorMessage] ?? error)。文字已保留，可重试。")
    }
    guard let id = result.atIndex(1)?.stringValue, !id.isEmpty, let name = result.atIndex(2)?.stringValue else { throw NotesFailure(detail: "备忘录未返回记录编号，文字已保留。") }
    return NoteReceipt(id: id, name: name, folder: result.atIndex(3)?.stringValue ?? "备忘录")
}

func openNote(id: String) {
    let source = "tell application \"Notes\"\nshow note id " + scriptLiteral(id) + "\nactivate\nend tell"
    var error: NSDictionary?
    NSAppleScript(source: source)?.executeAndReturnError(&error)
}

struct NotesWorkerRequest: Codable {
    let title: String
    let text: String
    let existingID: String?
}
struct NotesWorkerResponse: Codable {
    let receipt: NoteReceipt?
    let error: String?
}

// AppleScript runs on the helper process's main thread; it never blocks the island UI.
func runNotesWorker() {
    do {
        let input = FileHandle.standardInput.readDataToEndOfFile()
        let request = try JSONDecoder().decode(NotesWorkerRequest.self, from: input)
        let receipt = try insertIntoNotes(title: request.title, text: request.text, existingID: request.existingID)
        FileHandle.standardOutput.write(try JSONEncoder().encode(NotesWorkerResponse(receipt: receipt, error: nil)))
    } catch {
        let response = NotesWorkerResponse(receipt: nil, error: error.localizedDescription)
        if let data = try? JSONEncoder().encode(response) { FileHandle.standardOutput.write(data) }
        exit(1)
    }
}
// One cancellation token belongs to one immutable meeting save snapshot.
final class SaveCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
}

// Never wait indefinitely on an Apple event or a CLI. Poll monotonic time and
// escalate termination; even a child that ignores SIGTERM cannot hold up quit.
func runBoundedProcess(_ process: Process, timeout: TimeInterval,
    cancellation: SaveCancellation? = nil, terminationGrace: TimeInterval = 1, requireSuccess: Bool = true
) throws {
    if cancellation?.isCancelled == true { throw NotesFailure(detail: "保存已取消，可重试") }
    try process.run()
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while process.isRunning {
        if cancellation?.isCancelled == true || ProcessInfo.processInfo.systemUptime >= deadline {
            process.terminate()
            let stop = ProcessInfo.processInfo.systemUptime + terminationGrace
            while process.isRunning && ProcessInfo.processInfo.systemUptime < stop { Thread.sleep(forTimeInterval: 0.02) }
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            let reap = ProcessInfo.processInfo.systemUptime + 1
            while process.isRunning && ProcessInfo.processInfo.systemUptime < reap { Thread.sleep(forTimeInterval: 0.02) }
            throw NotesFailure(detail: cancellation?.isCancelled == true ? "保存已取消，可重试" : "处理超时。备忘录可能已写入，请检查后重试。")
        }
        Thread.sleep(forTimeInterval: 0.02)
    }
    guard !requireSuccess || process.terminationStatus == 0 else {
        throw NotesFailure(detail: "处理程序异常退出（退出码 \(process.terminationStatus)），文字已保留，可重试。")
    }
}

// All snapshots and final writes share this queue. Final output can never be
// overwritten by an older periodic snapshot, and no disk I/O runs on the UI thread.
final class MeetingBackupWriter: @unchecked Sendable {
    private let queue = DispatchQueue(label: "DuckIsland.meeting-backup", qos: .utility)
    private let lock = NSLock()
    private var count = 0
    var pending: Bool { lock.lock(); defer { lock.unlock() }; return count > 0 }
    private func changeCount(_ delta: Int) { lock.lock(); count += delta; lock.unlock() }
    func write(_ text: String, to url: URL, completion: @escaping (Result<Void, Error>) -> Void) {
        changeCount(1)
        queue.async {
            let result = Result { try text.write(to: url, atomically: true, encoding: .utf8) }
            completion(result)
            self.changeCount(-1)
        }
    }
    func writeFinal(_ text: String, to url: URL) throws {
        try queue.sync { try text.write(to: url, atomically: true, encoding: .utf8) }
    }
}

@MainActor final class MeetingSaveJobs {
    private var tokens: [UUID: SaveCancellation] = [:]
    // Keep unsaved snapshots across new meetings. Quit must not discard these.
    private(set) var unsaved: [UUID: String] = [:]
    var pending: Bool { !tokens.isEmpty }
    func begin(_ id: UUID, text: String) -> SaveCancellation {
        let token = SaveCancellation(); tokens[id] = token; unsaved[id] = text
        return token
    }
    func complete(_ id: UUID, result: BackgroundSaveResult) {
        tokens[id] = nil
        if result.hasDurableCopy { unsaved[id] = nil }
        else if !result.recoveryText.isEmpty { unsaved[id] = result.recoveryText }
    }
    func retain(_ id: UUID, text: String) { unsaved[id] = text }
    func recovered(_ id: UUID, text: String) {
        if unsaved[id] == text { recovered(id) }
    }
    func cancelAll() { tokens.values.forEach { $0.cancel() } }
    func recovered(_ id: UUID) { if tokens[id] == nil { unsaved[id] = nil } }
    func waitForCompletion(timeout: TimeInterval, pendingBackup: () -> Bool) async -> Bool {
        let start = ProcessInfo.processInfo.systemUptime
        while pending || pendingBackup() {
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            if elapsed >= timeout { cancelAll(); return false }
            if elapsed >= max(0, timeout - 3) { cancelAll() }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return true
    }
    var recoveryText: String { unsaved.values.sorted().joined(separator: "\n\n────────\n\n") }
}

func insertIntoNotesInBackground(title: String, text: String, existingID: String?, cancellation: SaveCancellation? = nil) throws -> NoteReceipt {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let inputURL = directory.appendingPathComponent("input.json")
    let outputURL = directory.appendingPathComponent("output.json")
    try JSONEncoder().encode(NotesWorkerRequest(title: title, text: text, existingID: existingID)).write(to: inputURL)
    FileManager.default.createFile(atPath: outputURL.path, contents: nil)
    let input = try FileHandle(forReadingFrom: inputURL), output = try FileHandle(forWritingTo: outputURL)
    defer { try? input.close(); try? output.close() }
    let process = Process()
    #if APP_STORE
    process.executableURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/NotesHelper")
    #else
    process.executableURL = Bundle.main.executableURL
    #endif
    process.arguments = ["--notes-worker"]
    process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
    try runBoundedProcess(process, timeout: 45, cancellation: cancellation, requireSuccess: false)
    let response = try JSONDecoder().decode(NotesWorkerResponse.self, from: Data(contentsOf: outputURL))
    guard process.terminationStatus == 0, let receipt = response.receipt else { throw NotesFailure(detail: response.error ?? "备忘录保存失败，文字已保留") }
    return receipt
}

enum LocalBackupState: Equatable {
    case saved
    case failed(String)
    var succeeded: Bool { if case .saved = self { return true }; return false }
}
struct BackgroundSaveResult {
    let analysis: String
    let analysisError: String
    let receipt: NoteReceipt?
    let error: String?
    let localBackup: LocalBackupState
    var recoveryText: String = ""
    var hasDurableCopy: Bool { localBackup.succeeded || receipt != nil }
    var statusMessage: String {
        switch (localBackup.succeeded, receipt != nil) {
        case (true, true): return analysisError.isEmpty ? "会议已保存" : "原文已保存；总结失败，可重试"
        case (true, false): return "本地备份已保存；备忘录未完成，可重试"
        case (false, true): return "已写入备忘录；本地备份失败，请重试备份"
        case (false, false): return "保存失败，尚无已确认副本；请复制文字或重试"
        }
    }
}
func meetingBody(transcript: String, analysis: String, error: String, warning: String) -> String {
    #if APP_STORE
    return "会议转写原文\n系统声音与麦克风分别标注，非发言人识别。\n\n" + transcript + (warning.isEmpty ? "" : "\n\n记录状态：" + warning)
    #else
    let summary = analysis.isEmpty ? "自动总结暂未完成：" + error : analysis
    return summary + "\n\n会议转写原文\n系统声音与麦克风分别标注，非发言人识别。\n\n" + transcript + (warning.isEmpty ? "" : "\n\n记录状态：" + warning)
    #endif
}
func defaultMeetingAnalyzer(_ transcript: String) throws -> String {
    #if APP_STORE
    return ""
    #else
    return try analyzeMeeting(transcript).rendered
    #endif
}
func finishMeetingInBackground(title: String, transcript: String, warning: String,
    backupURL: URL?, existingID: String?, analyze: Bool,
    previousAnalysis: String, previousError: String,
    analyzer: (String) throws -> String = defaultMeetingAnalyzer,
    exporter: (String, String, String?) throws -> NoteReceipt = { try insertIntoNotesInBackground(title: $0, text: $1, existingID: $2) },
    backupWriter: (String, URL) throws -> Void = { try $0.write(to: $1, atomically: true, encoding: .utf8) }
) -> BackgroundSaveResult {
    var analysis = previousAnalysis, analysisError = previousError
    #if !APP_STORE
    if analyze {
        do { analysis = try analyzer(transcript); analysisError = "" }
        catch { analysisError = error.localizedDescription }
    }
    #endif
    #if APP_STORE
    analysis = ""; analysisError = ""
    #endif
    let body = meetingBody(transcript: transcript, analysis: analysis, error: analysisError, warning: warning)
    let localBackup: LocalBackupState
    do {
        guard let backupURL else { throw NotesFailure(detail: "本地备份路径不可用") }
        try backupWriter(title + "\n\n" + body, backupURL)
        localBackup = .saved
    } catch { localBackup = .failed(error.localizedDescription) }
    // A failed local disk must not prevent an independent Notes save.
    do {
        let receipt = try exporter(title, body, existingID)
        return BackgroundSaveResult(analysis: analysis, analysisError: analysisError, receipt: receipt, error: nil, localBackup: localBackup, recoveryText: title + "\n\n" + body)
    } catch {
        return BackgroundSaveResult(analysis: analysis, analysisError: analysisError, receipt: nil, error: error.localizedDescription, localBackup: localBackup, recoveryText: title + "\n\n" + body)
    }
}

@MainActor func waitForSaveOperation(timeout: TimeInterval, operation: @escaping @MainActor () async -> Bool) async -> Bool {
    var result: Bool?
    Task { @MainActor in result = await operation() }
    let deadline = ProcessInfo.processInfo.systemUptime + timeout
    while result == nil && ProcessInfo.processInfo.systemUptime < deadline {
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return result ?? false
}
