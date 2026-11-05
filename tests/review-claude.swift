// Offline export/lifecycle checks. The opener is injected: no real Claude request is sent.
import Cocoa
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("review-claude-"+UUID().uuidString+" & 中文")
    defer { try? FileManager.default.removeItem(at:root) }
    let model = ReviewModel(storageRoot:root)
    let image = NSImage(size:NSSize(width:400,height:200),flipped:false) { rect in
        NSColor.white.setFill(); rect.fill()
        ("Synthetic review fixture" as NSString).draw(at:NSPoint(x:25,y:120),withAttributes:[.font:NSFont.systemFont(ofSize:20),.foregroundColor:NSColor.black]); return true
    }
    let png = try reviewPNG(image)
    let first = ReviewSnapshot(id:UUID(),image:image,png:png,frame:CGRect(x:0,y:0,width:400,height:200))
    let second = ReviewSnapshot(id:UUID(),image:image,png:png,frame:first.frame)
    let region = ReviewRegion(snapshotID:first.id,number:7,rect:CGRect(x:0.1,y:0.1,width:0.5,height:0.3))
    model.active = true; model.paused = true; model.snapshots = [first,second]; model.current = first
    model.regions = [region]; model.selectedID = region.id; model.voice.dictating = true
    var opened: URL?
    let task = Task { await model.sendToClaude { opened = $0 } }
    while !model.voice.voiceFinishing { try await Task.sleep(nanoseconds:1_000_000) }
    let finalText = "Final feedback & 中文 #7\n" + String(repeating:"keep every comment; ",count:1200)
    model.voice.receiveTranscript(finalText,final:true,failed:false)
    await task.value
    precondition(opened != nil && !model.active && !model.busy)
    let components = URLComponents(url:opened!,resolvingAgainstBaseURL:false)!
    precondition(components.scheme == "claude" && components.host == "cowork" && components.path == "/new")
    let files = components.queryItems!.filter { $0.name == "file" }.map { URL(fileURLWithPath:$0.value!) }
    precondition(files.map(\.lastPathComponent) == ["screen-01.png","screen-02.png","comments.txt"])
    precondition(files.allSatisfy { FileManager.default.fileExists(atPath:$0.path) })
    let comments = try String(contentsOf:files[2],encoding:.utf8)
    precondition(comments.contains(finalText) && comments.contains("#7") && comments.contains("screen-02.png 对应画面 2"))
    precondition(components.queryItems!.first(where:{$0.name == "q"})!.value!.count < 14000)
    precondition(NSImage(contentsOf:files[0])!.size == image.size)
    let marked = NSBitmapImageRep(data:try Data(contentsOf:files[0]))!
    let color = marked.colorAt(x:45,y:25)!.usingColorSpace(.deviceRGB)!
    precondition(color.blueComponent > color.redComponent, "Exported screenshot must retain numbered annotation")
    let store = ReviewStore()
    let folder = try await store.latest(root:root)!
    try "changed later".write(to:folder.appendingPathComponent("review.txt"),atomically:true,encoding:.utf8)
    let retainedComments = try String(contentsOf:files[2],encoding:.utf8)
    precondition(retainedComments == comments, "Opened draft attachments must be immutable")

    let failed = ReviewModel(storageRoot:root.appendingPathComponent("failure"))
    failed.active = true; failed.paused = true; failed.snapshots = [first]
    await failed.sendToClaude { _ in throw NotesFailure(detail:"fixture: app unavailable") }
    precondition(failed.active && failed.paused && !failed.busy && failed.snapshots.count == 1)
    precondition(failed.status.contains("未完成"))
    var retries = 0
    await failed.sendToClaude { _ in retries += 1 }
    precondition(retries == 1 && !failed.active)
    let empty = ReviewModel(); var emptyOpened = false
    await empty.sendToClaude { _ in emptyOpened = true }
    precondition(!emptyOpened)
    do { _ = try claudeReviewURL(files:Array(repeating:files[0],count:21)); fatalError("Accepted too many attachments") } catch {}
    do { _ = try claudeReviewURL(files:[URL(string:"https://example.com/x.png")!]); fatalError("Accepted nonlocal file") } catch {}

    // Keep a tiny synthetic packet for a separate desktop draft-opening check.
    let preview = URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("Claude-preview-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:preview,withIntermediateDirectories:true)
    let previewImage = preview.appendingPathComponent("screen-01.png")
    try Data(contentsOf:files[0]).write(to:previewImage)
    let previewComments = preview.appendingPathComponent("comments.txt")
    try "DuckIsland 集成验证（虚构数据）\n画面 1，#7：标题需要更清楚。仅测试附件准备，无需执行任何操作。".write(to:previewComments,atomically:true,encoding:.utf8)
    let link = try claudeReviewURL(files:[previewImage,previewComments])
    try link.absoluteString.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent("claude-preview-link.txt"),atomically:true,encoding:.utf8)
    print("PASS: annotated screenshots and full comments, URL escaping, immutable packet, final speech, successful handoff close, failure retention/retry, empty and attachment limits")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Claude handoff tests timed out") }
app.run()
