// Render only synthetic production views; never capture the desktop or start app services.
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
@MainActor func renderFixture<V: View>(_ view: V, _ name: String, _ size: NSSize) throws {
    let host = NSHostingView(rootView: view)
    host.frame = NSRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    host.layoutSubtreeIfNeeded()
    RunLoop.main.run(until: Date().addingTimeInterval(0.1))
    guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("bitmap") }
    host.cacheDisplay(in: host.bounds, to: bitmap)
    try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent(name + ".png"))
}
try MainActor.assumeIsolated {
    let model = Recorder()
    model.notchWidth = 180; model.notchHeight = 32
    model.recording = true; model.recordingStartedAt = Date().addingTimeInterval(-125); model.showMenu = true
    try renderFixture(IslandView(model: model), "recording-menu", NSSize(width:360,height:214))
    model.showMenu = false; model.expanded = true; model.recording = false
    model.transcript = String(repeating: "虚构会议内容：长文字回看与选择。\n", count: 20)
    model.savedNoteName = String(repeating: "虚构长标题", count: 15); model.savedNoteFolder = "Fixture"
    model.message = "转写不完整；本地保存失败，请重试；备忘录同步失败，原文仍可复制。"
    model.analysisError = "虚构错误"; model.audioStatus = "系统声音：已停止 · 麦克风：已停止"
    try renderFixture(IslandView(model: model), "results-errors", NSSize(width:460,height:440))
    model.recording = true; model.screenReader.visible = true
    let fixtureRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: fixtureRoot) }
    let fixtureImage = NSImage(size:NSSize(width:10,height:10),flipped:false) { rect in NSColor.white.setFill(); rect.fill(); return true }
    let ocr = ScreenReader(storageRoot: fixtureRoot)
    ocr.accept(ScreenReadResult(text:"虚构原文",image:try reviewPNG(fixtureImage)),target:ScreenTarget(id:42,pid:123,app:"Fixture",bundleID:"fixture",title:String(repeating:"虚构长窗口标题",count:12)),region:.zero)
    ocr.showLastResult()
    ocr.text = "虚构可编辑文字"; ocr.status = "保存失败：虚构错误。修改仍保留，请重试。"
    // Use the real dirty model; the error message itself is a visual fixture.
    let ocrModel = Recorder(screenReader: ocr)
    ocrModel.notchWidth = 180; ocrModel.notchHeight = 32; ocrModel.recording = true
    ocrModel.recordingStartedAt = model.recordingStartedAt; ocr.visible = true
    try renderFixture(IslandView(model: ocrModel), "ocr-recording", NSSize(width:420,height:382))
    print("PASS: offscreen synthetic production view renders")
}
