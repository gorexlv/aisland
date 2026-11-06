import Cocoa
import SwiftUI
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
Task { @MainActor in
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("mo-activity-"+UUID().uuidString)
    defer { try? FileManager.default.removeItem(at:root) }
    let listening = MoActivity(id:"listen",kind:.listening,title:"静默记录",target:.chat,level:0.4)
    let summary = MoActivity(id:"summary",kind:.summarizing,title:"正在整理",target:.summary)
    let error = MoActivity(id:"error",kind:.failed,title:"摘要失败",target:.summary)
    let state = MoActivityState.resolve([summary,error,listening])
    precondition(state.primary.id == listening.id && state.secondary.contains(where:{$0.id == summary.id}) && state.secondary.contains(where:{$0.id == error.id}), "Background work/errors must not mask microphone capture")
    let speaking = MoActivity(id:"speak",kind:.speaking,title:"正在回答",target:.chat,level:0.7)
    precondition(MoActivityState.resolve([listening,speaking]).primary.id == speaking.id)
    precondition(MoActivityState.resolve([]).primary.kind == .idle)
    var playback = MoPlaybackFeedback()
    precondition(playback.accept(playing:true,level:0.7,sequence:1,enabled:true) && playback.playing)
    precondition(playback.accept(playing:false,level:0,sequence:3,enabled:true) && !playback.playing)
    precondition(!playback.accept(playing:true,level:1,sequence:2,enabled:true) && !playback.playing)
    precondition(playback.accept(playing:true,level:1,sequence:4,enabled:false) && !playback.playing && playback.level == 0)
    let expired = MoActivity(id:"done",kind:.completed,title:"Done",expiresAt:Date.distantPast)
    precondition(MoActivityState.resolve([expired]).primary.kind == .idle)
    let model = ReviewModel(storageRoot:root)
    let recorder = Recorder(review:model)
    model.active = true; model.paused = true; model.listeningEnabled = true
    model.voice.unavailableReason = "fixture"
    model.voice.dictating = true
    precondition(model.activityState.primary.title == "静默记录")
    model.textChatBusy = true
    precondition(model.activityState.primary.kind == .thinking && model.activityState.secondary.contains(where:{$0.kind == .listening}))
    model.textChatBusy = false; model.voice.dictating = false
    recorder.screenReader.busy = true
    precondition(model.activityState.primary.kind == .reading)
    recorder.screenReader.busy = false
    let action = model.beginActivity("正在写入备忘录")
    precondition(model.activityState.primary.kind == .executing && model.activityState.primary.title == "正在写入备忘录")
    model.endActivity(action,result:"已写入备忘录")
    precondition(model.activityState.primary.kind == .completed)
    let newer = model.beginActivity("正在复制")
    model.endActivity(action,result:"old failure",failed:true)
    precondition(model.activityState.primary.title == "正在复制", "Stale action completion must not overwrite newer action")
    model.endActivity(newer,result:"复制失败",failed:true)
    precondition(model.activityState.primary.kind == .failed)
    model.workActivity = nil
    let image = NSImage(size:CGSize(width:600,height:400),flipped:false) { r in NSColor.white.setFill();r.fill();return true }
    let shot = ReviewSnapshot(id:UUID(),image:image,png:try reviewPNG(image),frame:CGRect(x:100,y:100,width:900,height:620))
    try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
    let blocked = root.appendingPathComponent("not-a-directory")
    try Data("fixture".utf8).write(to:blocked)
    let failing = ReviewModel(storageRoot:blocked)
    failing.active = true; failing.voice.unavailableReason = "fixture"; failing.snapshots = [shot]; failing.current = shot
    failing.finish()
    while failing.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(failing.workActivity?.kind == .failed && failing.workActivity?.title == "复制失败")
    failing.writeReviewToNotes()
    while failing.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(failing.workActivity?.kind == .failed && failing.workActivity?.title == "写入失败")
    failing.sendToCodex()
    while failing.busy { try await Task.sleep(nanoseconds:1_000_000) }
    precondition(failing.workActivity?.kind == .failed && failing.workActivity?.title == "打开失败", "Actual actions must expose failure when persistence fails before any external side effect")
    failing.panels.close()
    model.snapshots = [shot]; model.current = shot
    model.target = ScreenTarget(id:42,pid:-1,app:"Fixture",bundleID:"fixture",title:"Activity")
    model.regions = [ReviewRegion(snapshotID:shot.id,number:3,rect:CGRect(x:0.1,y:0.1,width:0.4,height:0.4))]
    model.selectedID = model.regions[0].id
    model.panels.showOverlay(shot)
    model.chatDraft = "Retain draft"
    model.showActivity(.chat)
    precondition(model.conversationTab == .chat && model.chatDraft == "Retain draft" && model.paused)
    precondition(model.activityState.context.contains("#3") && model.activityState.context.contains("Fixture"))
    model.historyPresented = true; model.paused = false; model.panels.hideOverlay()
    model.liveSummary.setEnabled(true)
    model.showActivity(.summary)
    precondition(model.conversationTab == .summary && model.historyPresented && !model.paused && model.panels.selectionOverlay == nil && model.panels.conversation != nil, "Summary routing from history must preserve history and not cover the target with a capture canvas")
    model.liveSummary.setEnabled(false)
    let destination = URL(fileURLWithPath:CommandLine.arguments[1])
    for (name,activities) in [("listening",[listening,summary]),("speaking",[speaking,listening]),("failure",[error])] {
        let snapshot = MoActivityState.resolve(activities)
        let view = NSHostingView(rootView:HStack { MoActivityAvatar(state:snapshot,size:32); MoActivityStatus(state:snapshot) }.padding(12).frame(width:240,height:65).background(Color.black).environment(\.colorScheme,.dark))
        view.frame = CGRect(x:0,y:0,width:240,height:65)
        let panel = NSPanel(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false); panel.contentView = view
        view.layoutSubtreeIfNeeded()
        let bitmap = view.bitmapImageRepForCachingDisplay(in:view.bounds)!
        view.cacheDisplay(in:view.bounds,to:bitmap)
        try bitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent("mo-activity-"+name+".png"))
        panel.close()
    }
    recorder.activityExpanded = true
    let island = NSHostingView(rootView:IslandView(model:recorder))
    island.frame = CGRect(x:0,y:0,width:400,height:220)
    let islandWindow = NSPanel(contentRect:island.frame,styleMask:.borderless,backing:.buffered,defer:false)
    islandWindow.contentView = island; island.layoutSubtreeIfNeeded()
    let islandBitmap = island.bitmapImageRepForCachingDisplay(in:island.bounds)!
    island.cacheDisplay(in:island.bounds,to:islandBitmap)
    try islandBitmap.representation(using:.png,properties:[:])!.write(to:destination.appendingPathComponent("mo-island-expanded.png"))
    islandWindow.close()
    model.panels.close()
    print("PASS: shared activity priority, concurrent badges, real actions, stale completion isolation, navigation, context and avatar render fixtures; no microphone/network")
    exit(0)
}
Task { try await Task.sleep(nanoseconds:20_000_000_000); fatalError("Activity tests timed out") }
app.run()
