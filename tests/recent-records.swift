import Foundation

@main struct RecentRecordTests {
    static func check(_ value: Bool, _ message: String) { if !value { fatalError(message) } }
    static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        check(try RecentRecords.load(root: root).isEmpty, "empty root")
        for dir in ["Meetings", "ScreenReads/fixture", "Reviews/legacy", "Reviews/broken"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: true)
        }
        let body = meetingBody(transcript: "original only", analysis: "会议总结\nsummary only\n\n关键结论\nnone\n\n可执行 Tickets\nTask one\n待确认事项\nnone", error: "", warning: "partial warning")
        try body.write(to: root.appendingPathComponent("Meetings/fixture.txt"), atomically: true, encoding: .utf8)
        try "diagnostics".write(to: root.appendingPathComponent("Meetings/fixture.diagnostics.txt"), atomically: true, encoding: .utf8)
        try "OCR fixture".write(to: root.appendingPathComponent("ScreenReads/fixture/文字.txt"), atomically: true, encoding: .utf8)
        try "Review fixture".write(to: root.appendingPathComponent("Reviews/legacy/review.txt"), atomically: true, encoding: .utf8)
        try Data([0xff, 0xfe, 0xff]).write(to: root.appendingPathComponent("Reviews/broken/review.txt"))
        let first = try RecentRecords.load(root: root)
        let restarted = try RecentRecords.load(root: root)
        check(first.count == 4 && restarted.count == 4, "three types reload and diagnostic exclusion")
        check(first.contains { $0.issue?.contains("损坏") == true }, "corrupt fixture degraded")
        check(first.contains { $0.issue?.contains("旧格式") == true }, "legacy fixture explicit")
        check(Set(first.map(\.kind)) == Set(["会议", "OCR", "批阅"]), "all types")
        let sections = RecordSections(body)
        check(sections.original.contains("original only") && !sections.original.contains("summary only"), "original copy scope")
        #if !APP_STORE
        check(sections.todos == "Task one", "todo copy scope")
        check(!sections.summary.contains("original only"), "summary copy scope")
        #else
        check(sections.summary.isEmpty && sections.todos.isEmpty, "store has no AI")
        #endif
        check(RecordSections("legacy text").summary.isEmpty, "legacy no invented summary")
        var calls = 0
        var stages: [String] = []
        let result = finishMeetingInBackground(title: "fixture", transcript: "original", warning: "partial", backupURL: root.appendingPathComponent("saved.txt"), existingID: nil, analyze: false, previousAnalysis: "", previousError: "", analyzer: { _ in calls += 1; return "forbidden" }, exporter: { _, _, _ in throw NotesFailure(detail: "offline") }, stage: { stages.append($0) })
        check(calls == 0 && result.localBackup.succeeded && result.receipt == nil, "disabled AI and independent local success")
        check(stages.count >= 2, "actual stages delivered")
        check(result.recoveryText.contains("partial"), "partial warning durable")
        let stagedURL = root.appendingPathComponent("staged.txt")
        var analyzed = false
        let offline = finishMeetingInBackground(title: "staged", transcript: "durable before network", warning: "", backupURL: stagedURL, existingID: nil, analyze: true, previousAnalysis: "", previousError: "", analyzer: { _ in
            analyzed = true
            check((try? String(contentsOf: stagedURL, encoding: .utf8))?.contains("durable before network") == true, "original saved before AI")
            throw NotesFailure(detail: "offline fixture")
        }, exporter: { _, _, _ in NoteReceipt(id: "fake", name: "fake", folder: "fake") })
        #if APP_STORE
        check(!analyzed && offline.analysisError.isEmpty, "store never invokes AI even when requested")
        #else
        check(analyzed && !offline.analysisError.isEmpty, "network failure retained")
        #endif
        check(offline.localBackup.succeeded && offline.receipt != nil, "network error independent from both saves")
        try FileManager.default.removeItem(at: root.appendingPathComponent("ScreenReads/fixture/文字.txt"))
        check(try RecentRecords.load(root: root).contains { $0.kind == "OCR" && $0.issue != nil }, "missing record does not crash")
        print("PASS: recent records reload, corrupt/legacy/empty fixtures, copy scopes, disabled AI, independent save and stages")
    }
}
