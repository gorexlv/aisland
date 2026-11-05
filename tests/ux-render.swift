// Synthetic fixtures only: no recording, screen capture, Notes, AI or permission prompts.
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
@MainActor func renderFixture<V: View>(_ view: V, _ name: String, _ size: NSSize) throws {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin:.zero,size:size)
    let window = NSWindow(contentRect:host.frame,styleMask:[.borderless],backing:.buffered,defer:false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until:Date().addingTimeInterval(0.1))
    let fitting = host.fittingSize
    precondition(fitting.width <= size.width + 1 && fitting.height <= size.height + 1, "Fixture does not fit: \(name) \(fitting)")
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in:host.bounds) else { fatalError("bitmap") }
    host.cacheDisplay(in:host.bounds,to:bitmap)
    try bitmap.representation(using:.png,properties:[:])!.write(to:URL(fileURLWithPath:CommandLine.arguments[1]).appendingPathComponent(name+".png"))
    print("RENDER \(name): \(Int(size.width))×\(Int(size.height)) points; fitting \(host.fittingSize)")
}
try MainActor.assumeIsolated {
    let model = Recorder()
    model.notchWidth = 180; model.notchHeight = 32
    model.recording = true; model.recordingStartedAt = Date().addingTimeInterval(-768); model.expanded = true
    model.transcript = "[12:02] 我的麦克风：这一版先聚焦核心流程，让第一次使用更轻松。\n[12:16] 我的麦克风：把次要操作放进工具栏，主要内容保持清晰。\n[12:35] 会议声音：周五一起看交互原型。"
    model.audioStatus = "麦克风：采集中 · 系统声音：静音"
    model.localBackupSaved = true
    try renderFixture(IslandView(model:model),"meeting",NSSize(width:494,height:484))
    model.showMenu = true
    try renderFixture(IslandView(model:model),"recording-menu",NSSize(width:360,height:214))
    model.showMenu = false; model.recording = false
    model.transcript = String(repeating:"[12:02] 我的麦克风：虚构长文字，阅读和选择不应被保存详情挤压。\n",count:30)
    model.savedNoteName = String(repeating:"虚构长标题",count:15)
    model.message = "转写不完整；本地保存失败：/synthetic/very/long/path；备忘录同步失败，原文仍可复制。"
    model.localBackupSaved = false; model.analysisError = "虚构错误"; model.audioStatus = "系统声音：已停止 · 麦克风：已停止"
    try renderFixture(IslandView(model:model),"meeting-long-failure",NSSize(width:494,height:484))
    try renderFixture(MeetingRecovery(model:model),"meeting-recovery",NSSize(width:380,height:390))
    model.busy = true
    try renderFixture(IslandView(model:model),"meeting-busy",NSSize(width:494,height:484))
    model.busy = false; model.transcript = ""
    try renderFixture(IslandView(model:model),"meeting-empty",NSSize(width:494,height:484))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let targets = [ScreenTarget(id:1,pid:-1,app:"浏览器",bundleID:"fixture",title:"设计讨论"),ScreenTarget(id:2,pid:-1,app:"文稿",bundleID:"fixture",title:String(repeating:"虚构长窗口标题",count:10)),ScreenTarget(id:3,pid:-1,app:"备忘录",bundleID:"fixture",title:"春季计划")]
    let reader = ScreenReader(storageRoot:root.appendingPathComponent("ocr"))
    let ocrModel = Recorder(screenReader:reader); ocrModel.notchWidth = 180; ocrModel.notchHeight = 32
    reader.visible = true; reader.targets = targets
    try renderFixture(IslandView(model:ocrModel),"reader",NSSize(width:494,height:reader.panelHeight+34))
    reader.targets = []
    try renderFixture(IslandView(model:ocrModel),"reader-empty",NSSize(width:494,height:reader.panelHeight+34))
    reader.busy = true
    try renderFixture(IslandView(model:ocrModel),"reader-busy",NSSize(width:494,height:reader.panelHeight+34))
    reader.busy = false
    let fixtureImage = NSImage(size:NSSize(width:800,height:420),flipped:false) { rect in
        NSColor(calibratedWhite:0.91,alpha:1).setFill(); rect.fill()
        ("FIELD / 工作台" as NSString).draw(at:NSPoint(x:35,y:365),withAttributes:[.font:NSFont.systemFont(ofSize:20),.foregroundColor:NSColor.darkGray])
        ("让想法，向前一步。" as NSString).draw(at:NSPoint(x:35,y:280),withAttributes:[.font:NSFont.systemFont(ofSize:34,weight:.semibold),.foregroundColor:NSColor.darkGray])
        ("虚构产品计划 · 渲染测试" as NSString).draw(at:NSPoint(x:35,y:235),withAttributes:[.font:NSFont.systemFont(ofSize:20),.foregroundColor:NSColor.gray])
        for i in 0..<5 { NSColor.systemGray.setFill(); NSRect(x:35+i*65,y:45,width:45,height:55+i*15).fill() }
        return true
    }
    let png = try reviewPNG(fixtureImage)
    reader.accept(ScreenReadResult(text:"虚构原文",image:png),target:targets[1],region:.zero)
    reader.showLastResult(); reader.text = "虚构可编辑文字\n" + String(repeating:"长文字保持原有编辑与滚动。",count:30)
    reader.status = "保存失败：虚构错误，修改仍保留，请重试。"
    ocrModel.recording = true; ocrModel.recordingStartedAt = model.recordingStartedAt
    try renderFixture(IslandView(model:ocrModel),"reader-unsaved-meeting",NSSize(width:494,height:reader.panelHeight+122))
    let review = ReviewModel(storageRoot:root.appendingPathComponent("review"))
    review.active = true; review.paused = true; review.target = targets[0]
    let shot = ReviewSnapshot(id:UUID(),image:fixtureImage,png:png,frame:CGRect(x:0,y:0,width:800,height:420),capturedAt:Date(timeIntervalSince1970:1000))
    review.snapshots = [shot]; review.current = shot
    review.regions = [ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0.025,y:0.22,width:0.55,height:0.22),feedback:"标题可以更短一些，让主要操作更突出。")]
    review.status = "虚构测试：本地批阅已保存"
    try renderFixture(ReviewSidebar(model:review,voice:review.voice),"review",NSSize(width:494,height:680))
    review.selectedID = review.regions[0].id; review.voice.draft = review.regions[0].feedback
    review.voice.unavailableReason = "会议录音中，可输入文字"
    try renderFixture(ReviewSidebar(model:review,voice:review.voice),"review-edit-meeting",NSSize(width:494,height:680))
    review.status = "保存失败：虚构错误，/synthetic/long/path，修改仍保留"
    try renderFixture(ReviewSidebar(model:review,voice:review.voice),"review-failure",NSSize(width:494,height:680))
    review.busy = true
    try renderFixture(ReviewSidebar(model:review,voice:review.voice),"review-busy",NSSize(width:494,height:680))
    review.busy = false; review.selectedID = nil; review.snapshots = []; review.regions = []
    review.recoveryFolder = root; review.paused = false; review.current = nil; review.status = "尚未截取"
    try renderFixture(ReviewSidebar(model:review,voice:review.voice),"review-empty-recovery",NSSize(width:494,height:580))
    try renderFixture(MeetingSettings(model:model),"meeting-settings",NSSize(width:340,height:170))
    let records = RecordWindows()
    records.records = [RecentRecord(url:root,date:Date(timeIntervalSince1970:1000),kind:"会议",title:"虚构长标题：产品讨论与后续计划",text:"虚构会议内容",issue:nil)]
    try renderFixture(RecentRecordsView(model:records),"recent-records",NSSize(width:760,height:580))
    try renderFixture(RecordResultView(sections:RecordSections("虚构原文\n"+String(repeating:"长结果内容，保留选择复制。\n",count:20))),"result",NSSize(width:760,height:580))
    let source = "[00:01] 我的麦克风：一\n[00:02] 我的麦克风：二\n[00:03] 会议声音：三\nunknown source stays verbatim"
    let compact = compactTranscript(source)
    precondition(compact.components(separatedBy:"麦克风").count == 2)
    precondition(compact.contains("00:02  二") && compact.contains("系统声音") && compact.contains("unknown source stays verbatim"))
    precondition(source.contains("我的麦克风：二"))
    precondition(ScreenReader(storageRoot:root).panelHeight < 440)
    model.recording = true; model.expanded = true; model.transcript = "[12:02] 我的麦克风：这一版先聚焦核心流程，让第一次使用更轻松。\n[12:16] 我的麦克风：把次要操作放进工具栏，主要内容保持清晰。\n[12:35] 会议声音：周五一起看交互原型。"
    model.audioStatus = "麦克风：采集中 · 系统声音：静音"; model.message = "虚构状态"; model.localBackupSaved = true
    let cleanReader = ScreenReader(storageRoot:root); cleanReader.targets = targets; cleanReader.visible = true
    let cleanModel = Recorder(screenReader:cleanReader); cleanModel.notchWidth = 180; cleanModel.notchHeight = 32
    review.snapshots = [shot]; review.current = shot; review.selectedID = nil; review.paused = true
    review.regions = [ReviewRegion(snapshotID:shot.id,number:1,rect:CGRect(x:0.025,y:0.22,width:0.55,height:0.22),feedback:"标题可以更短一些，让主要操作更突出。")]
    review.status = "虚构测试：本地批阅已保存"
    try renderFixture(HStack(alignment:.top,spacing:24) {
        IslandView(model:model).frame(width:494,height:484)
        IslandView(model:cleanModel).frame(width:494,height:444)
        VStack(spacing:0) {
            Image(nsImage:MascotAssets.images["duck"]!).resizable().scaledToFit().frame(width:23,height:23).frame(width:208,height:34).background(.black,in:UnevenRoundedRectangle(bottomLeadingRadius:18,bottomTrailingRadius:18))
            ReviewSidebar(model:review,voice:review.voice).frame(width:494,height:580)
        }
    }.padding(24).background(Color(white:0.86)),"native-comparison",NSSize(width:1578,height:662))
    print("PASS: offscreen synthetic production view renders")
}
