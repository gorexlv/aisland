import Cocoa

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
func insertIntoNotesInBackground(title: String, text: String, existingID: String?) throws -> NoteReceipt {
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
    try process.run()
    process.waitUntilExit()
    let response = try JSONDecoder().decode(NotesWorkerResponse.self, from: Data(contentsOf: outputURL))
    guard let receipt = response.receipt else { throw NotesFailure(detail: response.error ?? "备忘录保存失败，文字已保留") }
    return receipt
}

struct BackgroundSaveResult {
    let analysis: String
    let analysisError: String
    let receipt: NoteReceipt?
    let error: String?
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
    exporter: (String, String, String?) throws -> NoteReceipt = insertIntoNotesInBackground
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
    do {
        if let backupURL { try (title + "\n\n" + body).write(to: backupURL, atomically: true, encoding: .utf8) }
        let receipt = try exporter(title, body, existingID)
        return BackgroundSaveResult(analysis: analysis, analysisError: analysisError, receipt: receipt, error: nil)
    } catch {
        return BackgroundSaveResult(analysis: analysis, analysisError: analysisError, receipt: nil, error: error.localizedDescription)
    }
}
