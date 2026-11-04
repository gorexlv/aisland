import Cocoa
import SwiftUI

@MainActor final class ReviewPanels {
    weak var model: ReviewModel?
    var sidebar: NSPanel?
    var overlay: NSPanel?
    private var highlights: [NSPanel] = []
    init(model:ReviewModel) { self.model = model }
    private func panel(_ frame:CGRect, level:Int) -> NSPanel {
        let p = IslandPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.hidesOnDeactivate = false
        p.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+level)
        p.collectionBehavior = [.fullScreenAuxiliary,.stationary,.ignoresCycle]
        p.animationBehavior = .none; p.isReleasedWhenClosed = false
        return p
    }
    var desktopTop:CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    func showSidebar() {
        guard let model else { return }
        if sidebar == nil {
            let screen = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1200,height:800)
            let p = panel(NSRect(x:screen.maxX-292,y:screen.maxY-590,width:280,height:580),level:3)
            p.hasShadow = true; p.contentView = NSHostingView(rootView:ReviewSidebar(model:model,voice:model.voice))
            sidebar = p
        }
        sidebar?.orderFrontRegardless()
    }
    func positionSidebar(_ frame: CGRect) {
        showSidebar()
        let target = reviewScreenRect(frame,desktopTop:desktopTop)
        let screen = NSScreen.screens.max { $0.frame.intersection(target).width * $0.frame.intersection(target).height < $1.frame.intersection(target).width * $1.frame.intersection(target).height }?.visibleFrame ?? NSScreen.main!.visibleFrame
        let width:CGFloat = min(280,screen.width), height:CGFloat = min(580,screen.height-20)
        let right = target.maxX+8, left = target.minX-width-8
        let x = right+width <= screen.maxX ? right : (left >= screen.minX ? left : screen.maxX-width-8)
        let y = max(screen.minY+8,min(target.maxY-height,screen.maxY-height-8))
        sidebar?.setFrame(NSRect(x:x,y:y,width:width,height:height),display:true)
    }
    func showHighlights(_ targets:[ScreenTarget]) async {
        clearHighlights()
        guard let model else { return }
        for target in targets.reversed() {
            guard model.active, model.picking else { clearHighlights(); return }
            guard let window = try? await resolveScreenWindow(target) else { continue }
            guard model.active, model.picking else { clearHighlights(); return }
            let p = panel(reviewScreenRect(window.frame,desktopTop:desktopTop),level:1)
            let view = ReviewHighlight(frame:NSRect(origin:.zero,size:p.frame.size))
            view.label = target.label
            view.choose = { [weak model] in Task { @MainActor in await model?.choose(target) } }
            p.contentView = view; p.orderFrontRegardless(); highlights.append(p)
        }
        sidebar?.orderFrontRegardless()
    }
    func clearHighlights() { highlights.forEach{$0.close()}; highlights = [] }
    func showOverlay(_ shot:ReviewSnapshot) {
        hideOverlay(); guard let model else { return }
        let p = panel(reviewScreenRect(shot.frame,desktopTop:desktopTop),level:2)
        let canvas = ReviewCanvas(frame:NSRect(origin:.zero,size:p.frame.size)); canvas.model = model; canvas.snapshot = shot
        p.contentView = canvas; overlay = p; p.orderFrontRegardless(); sidebar?.orderFrontRegardless()
    }
    func redraw() { overlay?.contentView?.needsDisplay = true }
    func hideOverlay() { overlay?.close(); overlay = nil }
    func hideForWorkspace() { overlay?.orderOut(nil); sidebar?.orderOut(nil) }
    func close() { clearHighlights(); hideOverlay(); sidebar?.close(); sidebar = nil }
}

final class ReviewHighlight:NSView {
    var label = ""
    var choose:(()->Void)?
    override func draw(_ dirtyRect:NSRect) {
        NSColor.systemYellow.withAlphaComponent(0.07).setFill(); bounds.fill()
        NSColor.systemYellow.setStroke(); let border = NSBezierPath(roundedRect:bounds.insetBy(dx:3,dy:3),xRadius:8,yRadius:8); border.lineWidth = 5; border.stroke()
        let badge = NSRect(x:8,y:bounds.height-34,width:min(bounds.width-16,380),height:26)
        NSColor.black.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect:badge,xRadius:5,yRadius:5).fill()
        ("点击选择 · " + label as NSString).draw(in:badge.insetBy(dx:8,dy:4),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent) { choose?() }
}
final class ReviewCanvas:NSView {
    weak var model: ReviewModel?
    var snapshot:ReviewSnapshot?
    private var start:CGPoint?
    private var current:CGPoint?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func draw(_ dirtyRect:NSRect) {
        guard let shot = snapshot, let model else { return }
        shot.image.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        let badge = NSRect(x:8,y:8,width:250,height:24)
        NSColor.black.withAlphaComponent(0.85).setFill(); badge.fill()
        let timestamp = shot.capturedAt.map { $0.formatted(date:.omitted,time:.standard) } ?? "未知（旧记录）"
        ("截取画面 · " + timestamp as NSString).draw(in:badge.insetBy(dx:6,dy:4),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
        for region in model.regions where region.snapshotID == shot.id {
            let r = CGRect(x:region.rect.minX*bounds.width,y:region.rect.minY*bounds.height,width:region.rect.width*bounds.width,height:region.rect.height*bounds.height)
            let color = region.id == model.selectedID ? NSColor.systemYellow : NSColor.systemOrange
            color.withAlphaComponent(0.12).setFill(); r.fill()
            color.setStroke(); let path = NSBezierPath(rect:r); path.lineWidth = 3; path.stroke()
            let badge = NSRect(x:r.minX,y:r.minY,width:32,height:22)
            color.setFill(); badge.fill()
            ("#\(region.number)" as NSString).draw(in:badge.insetBy(dx:3,dy:3),withAttributes:[.font:NSFont.boldSystemFont(ofSize:12),.foregroundColor:NSColor.black])
        }
        if let start, let current, let selection = reviewSelection(start,current,size:bounds.size) {
            let r = NSRect(x:selection.minX*bounds.width,y:selection.minY*bounds.height,width:selection.width*bounds.width,height:selection.height*bounds.height)
            NSColor.systemYellow.setStroke(); let path = NSBezierPath(rect:r); path.lineWidth=2; path.setLineDash([5,3],count:2,phase:0); path.stroke()
        }
    }
    override func keyDown(with event:NSEvent) {
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            Task { await model?.undoEdit() }; return
        }
        if event.modifierFlags.contains(.command), event.keyCode == 51 {
            Task { await model?.deleteSelectedRegion() }; return
        }
        super.keyDown(with:event)
    }
    override func mouseDown(with event:NSEvent) { window?.makeFirstResponder(self); start = convert(event.locationInWindow,from:nil); current = start }
    override func mouseDragged(with event:NSEvent) { current = convert(event.locationInWindow,from:nil); needsDisplay = true }
    override func mouseUp(with event:NSEvent) {
        guard let start, let model else { return }
        let end = convert(event.locationInWindow,from:nil)
        if let rect = reviewSelection(start,end,size:bounds.size) { model.addRegion(rect) }
        else if let shot = snapshot {
            let point = CGPoint(x:end.x/bounds.width,y:end.y/bounds.height)
            if let region = model.regions.last(where:{$0.snapshotID == shot.id && $0.rect.contains(point)}) { model.select(region.id) }
        }
        self.start = nil; current = nil; needsDisplay = true
    }
}

struct ReviewSidebar:View {
    @ObservedObject var model:ReviewModel
    @ObservedObject var voice:VoiceInput
    @State private var pendingDelete: ReviewSnapshot?
    var body:some View {
        VStack(alignment:.leading,spacing:10) {
            HStack {
                Text("🦜 批阅").font(.system(size:15,weight:.semibold))
                Spacer()
                Button { model.close() } label:{Image(systemName:"xmark")}.help("保存并关闭批阅")
            }
            Text(model.target?.label ?? "选择一个窗口").font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)
            if model.recoveryFolder != nil && model.snapshots.isEmpty {
                Button("恢复最近一次批阅") { model.restoreLatest() }.disabled(model.busy)
            }
            if model.picking {
                ScrollView {
                    VStack(alignment:.leading,spacing:6) {
                        ForEach(model.targets) { item in
                            Button { Task { await model.choose(item) } } label: {
                                Text(item.label).font(.system(size:12)).lineLimit(2).frame(maxWidth:.infinity,alignment:.leading).padding(8)
                                    .background(.white.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                            }
                        }
                    }
                }
                Button("重新扫描") { model.refreshPicker() }.disabled(model.busy)
            } else {
                Button {
                    if model.paused { model.resume() } else { model.pause() }
                } label: {
                    HStack(spacing:12) {
                        ZStack {
                            Circle().fill(.white.opacity(0.12)).frame(width:46,height:46)
                            if model.busy {
                                ProgressView().controlSize(.regular).tint(.white)
                            } else {
                                Image(systemName:model.paused ? "arrow.uturn.backward" : "camera.viewfinder")
                                    .font(.system(size:26,weight:.bold))
                            }
                        }
                        VStack(alignment:.leading,spacing:4) {
                            Text(model.busy ? "处理中…" : (model.paused ? "返回实时窗口" : "截取画面并标注"))
                                .font(.system(size:15,weight:.bold))
                            Text(model.busy ? model.status : (model.paused ? "画面已冻结 · 可框选批阅" : "窗口可操作 · 点击截取画面"))
                                .font(.system(size:11)).lineLimit(2)
                        }
                        Spacer(minLength:0)
                    }.padding(12).frame(maxWidth:.infinity,minHeight:76,alignment:.leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(ReviewCaptureButtonStyle(paused:model.paused))
                .disabled(model.busy)
                .accessibilityLabel(model.busy ? "处理中" : (model.paused ? "返回实时窗口" : "截取画面并标注"))
                .accessibilityValue(model.paused ? "画面已冻结" : "窗口可操作")
                HStack(spacing:5) {
                    Circle().fill(model.paused ? Color.orange : Color.green).frame(width:7,height:7)
                    Text(model.paused ? "截图标注中" : "操作中").font(.system(size:11,weight:.semibold))
                    Spacer()
                    Text("\(model.snapshots.count) 张 · \(model.regions.count) 条").font(.system(size:10)).foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment:.leading,spacing:10) {
                            if model.snapshots.isEmpty { Text("每次截取保留一张完整画面，\n在画面上框选并添加评审意见。")
                                .font(.system(size:12)).foregroundStyle(.secondary).padding(.vertical,20) }
                            ForEach(Array(model.snapshots.enumerated()),id: \.element.id) { index, shot in
                                VStack(alignment:.leading,spacing:6) {
                                    HStack {
                                        Text("画面 \(index+1)").font(.system(size:11,weight:.bold))
                                        Spacer()
                                        Button("删除截图") { pendingDelete = shot }.disabled(model.busy)
                                    }
                                    Text(shot.capturedAt.map { "截取于 " + $0.formatted(date:.omitted,time:.standard) } ?? "截取时间未知（旧记录）")
                                        .font(.system(size:10)).foregroundStyle(.secondary)
                                    Image(nsImage:annotatedReviewImage(shot,regions:model.regions.filter{$0.snapshotID == shot.id}))
                                        .resizable().scaledToFit().frame(maxHeight:160)
                                    ForEach(model.regions.filter{$0.snapshotID == shot.id}) { region in
                                        Button { model.select(region.id) } label: {
                                            HStack(alignment:.top,spacing:5) {
                                                Text("#\(region.number)").fontWeight(.semibold)
                                                Text(region.feedback.isEmpty ? "点击填写评审意见" : region.feedback).lineLimit(4)
                                                Spacer(minLength:0)
                                            }.font(.system(size:11)).padding(6).frame(maxWidth:.infinity,alignment:.leading)
                                                .background(model.selectedID == region.id ? Color.yellow.opacity(0.12) : .clear,in:RoundedRectangle(cornerRadius:6))
                                        }.id(region.id)
                                    }
                                    if !model.regions.contains(where:{$0.snapshotID == shot.id}) {
                                        Text("尚未添加标记").font(.system(size:10)).foregroundStyle(.secondary)
                                    }
                                }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                                    .background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:9))
                            }

                        }
                    }.onChange(of:model.selectedID) { if let id = model.selectedID { proxy.scrollTo(id,anchor:.bottom) } }
                }
                if let id = model.selectedID, let region = model.regions.first(where:{$0.id == id}) {
                    HStack {
                        Text("#\(region.number) 评审意见").font(.system(size:11,weight:.medium))
                        Spacer()
                        Button { voice.toggleVoice() } label:{Image(systemName:voice.dictating ? "stop.circle.fill" : "mic.fill").foregroundStyle(voice.dictating ? .red : .yellow)}
                            .disabled(model.busy || voice.voicePreparing || voice.voiceFinishing || voice.unavailableReason != nil).help(voice.dictating ? "结束语音" : "语音评审意见")
                    }
                    TextEditor(text:$voice.draft).font(.system(size:12)).frame(height:65).scrollContentBackground(.hidden)
                        .padding(5).background(.white.opacity(0.07),in:RoundedRectangle(cornerRadius:7)).disabled(voice.voiceActive)
                    Text(voice.unavailableReason ?? voice.status).font(.system(size:10)).foregroundStyle(voice.voiceActive ? .yellow : .gray).lineLimit(2)
                }
                Button { model.finish() } label: {
                    Label(model.copied ? "已复制 · 再次复制" : "复制全部",systemImage:"doc.on.doc").frame(maxWidth:.infinity).padding(8)
                        .background(.yellow.opacity(0.17),in:RoundedRectangle(cornerRadius:8))
                }.disabled(model.snapshots.isEmpty || model.busy)
                HStack {
                    Button("删除选中标记") { Task { await model.deleteSelectedRegion() } }
                        .disabled(model.selectedID == nil || model.busy).keyboardShortcut(.delete, modifiers:[.command])
                    Button("撤销") { Task { await model.undoEdit() } }
                        .disabled(!model.canUndo || model.busy).keyboardShortcut("z",modifiers:[.command])
                }.font(.system(size:11))
                Button("保存并关闭") { model.close() }.disabled(model.busy)
                Button("查看本地批阅") { model.reveal() }.font(.system(size:10)).disabled(model.snapshots.isEmpty)
            }
            if model.busy { ProgressView().controlSize(.small) }
            Text(model.status).font(.system(size:10)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
        }.padding(14).frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top)
            .buttonStyle(.plain).foregroundStyle(.white).background(Color(white:0.075),in:RoundedRectangle(cornerRadius:15))
            .preferredColorScheme(.dark)
            .alert("删除截图及其意见？",isPresented:Binding(get:{ pendingDelete != nil },set:{ if !$0 { pendingDelete = nil } })) {
                Button("取消",role:.cancel) { pendingDelete = nil }
                Button("删除",role:.destructive) {
                    if let shot = pendingDelete { Task { await model.deleteSnapshot(shot.id) } }
                    pendingDelete = nil
                }
            } message: {
                Text("将删除这张截图及 \(model.regions.filter { $0.snapshotID == pendingDelete?.id }.count) 条意见。删除后可点「撤销」恢复。")
            }
    }
}

private struct ReviewCaptureButtonStyle:ButtonStyle {
    let paused:Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration) -> some View {
        let color:Color = paused ? .orange : .green
        configuration.label
            .foregroundStyle(.white)
            .background(color.opacity(configuration.isPressed ? 0.5 : 0.28),in:RoundedRectangle(cornerRadius:12))
            .overlay(RoundedRectangle(cornerRadius:12).strokeBorder(color.opacity(0.8),lineWidth:1.5))
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.97 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration:0.12),value:configuration.isPressed)
            .animation(reduceMotion ? nil : .easeInOut(duration:0.18),value:paused)
    }
}
