import Foundation

@main struct SaveReliabilityTests {
    static func check(_ condition: Bool, _ message: String) {
        if !condition { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.txt")
        func save(_ diskFails: Bool, _ notesFail: Bool) -> BackgroundSaveResult {
            finishMeetingInBackground(title: "fixture", transcript: "original", warning: "", backupURL: url,
                existingID: nil, analyze: true, previousAnalysis: "", previousError: "",
                analyzer: { _ in "generated summary" },
                exporter: { _, _, _ in
                    if notesFail { throw NotesFailure(detail: "notes failure") }
                    return NoteReceipt(id: "fixture", name: "fixture", folder: "fixture")
                }, backupWriter: { text, target in
                    if diskFails { throw NotesFailure(detail: "disk failure") }
                    try text.write(to: target, atomically: true, encoding: .utf8)
                })
        }
        let failed = save(true, true)
        check(!failed.hasDurableCopy && !failed.statusMessage.contains("本地备份已保存"), "disk failure must not claim backup")
        check(save(false, true).localBackup.succeeded, "Notes failure must retain local success")
        check(save(true, false).receipt != nil, "disk failure must not prevent Notes")
        let jobs = MeetingSaveJobs(), old = UUID(), new = UUID()
        _ = jobs.begin(old, text: "original")
        jobs.complete(old, result: failed)
        _ = jobs.begin(new, text: "new original")
        check(jobs.recoveryText.contains("original"), "new meeting retains old recovery")
        #if !APP_STORE
        check(jobs.recoveryText.contains("generated summary"), "failed save retains generated analysis")
        #endif
        let writer = MeetingBackupWriter()
        for i in 0..<100 { writer.write("snapshot \(i)", to: url) { _ in } }
        try await Task.detached { try writer.writeFinal("final", to: url) }.value
        check(try String(contentsOf: url, encoding: .utf8) == "final", "final write follows every snapshot")
        check(!writer.pending, "backup queue drains")
        let revision = UUID()
        jobs.retain(revision, text: "newer")
        jobs.recovered(revision, text: "older")
        check(jobs.unsaved[revision] == "newer", "stale backup cannot clear newer recovery")
        jobs.recovered(revision, text: "newer")
        check(jobs.unsaved[revision] == nil, "successful matching save clears recovery")
        let pending = MeetingSaveJobs(), id = UUID()
        let token = pending.begin(id, text: "recover me")
        let started = ProcessInfo.processInfo.systemUptime
        check(!(await pending.waitForCompletion(timeout: 0.15, pendingBackup: { false })), "uncancellable job blocks quit")
        check(token.isCancelled && ProcessInfo.processInfo.systemUptime - started < 1, "quit timeout is bounded and cancels")
        pending.complete(id, result: save(false, true))
        check(await pending.waitForCompletion(timeout: 0.1, pendingBackup: { false }), "quit retry succeeds after completion")
        let cancellable = MeetingSaveJobs(), cancellableID = UUID()
        let cancellation = cancellable.begin(cancellableID, text: "snapshot")
        Task { @MainActor in
            while !cancellation.isCancelled { try? await Task.sleep(nanoseconds: 10_000_000) }
            cancellable.complete(cancellableID, result: save(false, true))
        }
        check(await cancellable.waitForCompletion(timeout: 0.5, pendingBackup: { false }), "cooperative cancellation completes quit")
        check(!(await waitForSaveOperation(timeout: 0.05) {
            try? await Task.sleep(nanoseconds: 200_000_000)
            return true
        }), "uncancellable stop cannot hold quit")
        for script in ["while :; do :; done", "trap '' TERM; while :; do :; done", "exit 7"] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
            let start = ProcessInfo.processInfo.systemUptime
            do {
                try runBoundedProcess(process, timeout: 0.1, terminationGrace: 0.1)
                check(false, "failed helper must throw")
            } catch {}
            check(!process.isRunning, "helper must be reaped")
            check(ProcessInfo.processInfo.systemUptime - start < 2, "helper timeout bounded")
        }
        let process = Process(), cancelled = SaveCancellation()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "while :; do :; done"]
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { cancelled.cancel() }
        do { try runBoundedProcess(process, timeout: 30, cancellation: cancelled, terminationGrace: 0.1); check(false, "cancel throws") } catch {}
        check(!process.isRunning, "cancelled helper exits")
        print("PASS: process timeout, SIGTERM escalation, abnormal exit, cancellation, write ordering, quit retry")
        print("PASS: independent save outcomes and cross-session recovery")
    }
}
