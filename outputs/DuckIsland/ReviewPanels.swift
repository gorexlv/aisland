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
    var islandExtraHeight: () -> CGFloat = { 0 }
    var desktopTop:CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    func showSidebar() {
        guard let model else { return }
        if sidebar == nil {
            let p = panel(sidebarFrame(),level:3)
            p.hasShadow = true; p.contentView = NSHostingView(rootView:ReviewSidebar(model:model,voice:model.voice))
            sidebar = p
        }
        sidebar?.orderFrontRegardless()
    }
    func positionSidebar(_ frame: CGRect) {
        showSidebar()
        sidebar?.setFrame(sidebarFrame(),display:true)
    }
    private func sidebarFrame() -> NSRect {
        guard let screen = NSScreen.screens.first(where:{$0.safeAreaInsets.top > 0}) ?? NSScreen.main else {
            return NSRect(x:0,y:0,width:494,height:680)
        }
        let top = screen.frame.maxY - max(32,screen.safeAreaInsets.top) - 2 - islandExtraHeight()
        let width = min(494,screen.visibleFrame.width-16)
        let height = min(680,top-screen.visibleFrame.minY-8)
        return NSRect(x:screen.frame.midX-width/2,y:top-height,width:width,height:height)
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
        NSColor.systemBlue.withAlphaComponent(0.07).setFill(); bounds.fill()
        NSColor.systemBlue.setStroke(); let border = NSBezierPath(roundedRect:bounds.insetBy(dx:3,dy:3),xRadius:8,yRadius:8); border.lineWidth = 5; border.stroke()
        let badge = NSRect(x:8,y:bounds.height-34,width:min(bounds.width-16,380),height:26)
        NSColor.black.withAlphaComponent(0.9).setFill(); NSBezierPath(roundedRect:badge,xRadius:5,yRadius:5).fill()
        ("点击选择 · " + label as NSString).draw(in:badge.insetBy(dx:8,dy:4),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent) { choose?() }
}
final class ReviewCanvas:NSView {
    weak var model: ReviewModel?
    var snapshot:ReviewSnapshot?
    var showsTimestamp = true
    private var start:CGPoint?
    private var current:CGPoint?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func draw(_ dirtyRect:NSRect) {
        guard let shot = snapshot, let model else { return }
        shot.image.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        if showsTimestamp {
        let badge = NSRect(x:8,y:8,width:250,height:24)
        NSColor.black.withAlphaComponent(0.85).setFill(); badge.fill()
        let timestamp = shot.capturedAt.map { $0.formatted(date:.omitted,time:.standard) } ?? "未知（旧记录）"
        ("截取画面 · " + timestamp as NSString).draw(in:badge.insetBy(dx:6,dy:4),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
        }
        for region in model.regions where region.snapshotID == shot.id {
            let r = CGRect(x:region.rect.minX*bounds.width,y:region.rect.minY*bounds.height,width:region.rect.width*bounds.width,height:region.rect.height*bounds.height)
            let color = NSColor.systemBlue.withAlphaComponent(region.id == model.selectedID ? 1 : 0.75)
            color.withAlphaComponent(0.12).setFill(); r.fill()
            color.setStroke(); let path = NSBezierPath(rect:r); path.lineWidth = 3; path.stroke()
            let badge = NSRect(x:r.minX,y:r.minY,width:32,height:22)
            color.setFill(); badge.fill()
            ("#\(region.number)" as NSString).draw(in:badge.insetBy(dx:3,dy:3),withAttributes:[.font:NSFont.boldSystemFont(ofSize:12),.foregroundColor:NSColor.white])
        }
        if let start, let current, let selection = reviewSelection(start,current,size:bounds.size) {
            let r = NSRect(x:selection.minX*bounds.width,y:selection.minY*bounds.height,width:selection.width*bounds.width,height:selection.height*bounds.height)
            NSColor.systemBlue.setStroke(); let path = NSBezierPath(rect:r); path.lineWidth=2; path.setLineDash([5,3],count:2,phase:0); path.stroke()
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
    override func mouseDown(with event:NSEvent) { guard model?.paused == true, model?.current?.id == snapshot?.id, model?.busy == false else { return }; window?.makeFirstResponder(self); start = convert(event.locationInWindow,from:nil); current = start }
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
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("截图批阅").font(.system(size:14,weight:.semibold))
                Spacer()
                ToolButton(title:"最近记录",symbol:"clock.arrow.circlepath") { RecordWindows.shared.show() }
                if model.recoveryFolder != nil && model.snapshots.isEmpty {
                    ToolButton(title:"恢复最近一次批阅",symbol:"arrow.counterclockwise") { model.restoreLatest() }.disabled(model.busy)
                }
                ToolButton(title:"保存并关闭批阅",symbol:"xmark") { model.close() }.disabled(model.busy)
            }.padding(14)
            Divider()
            HStack {
                Text(model.target?.label ?? "选择窗口").font(.system(size:12)).foregroundStyle(IslandStyle.secondary).lineLimit(2).help(model.target?.label ?? "选择窗口")
                Spacer(minLength:8)
                if model.busy { ProgressView().controlSize(.small) }
                if model.picking {
                    ToolButton(title:"重新扫描窗口",symbol:"arrow.clockwise") { model.refreshPicker() }.disabled(model.busy)
                } else {
                    Button { if model.paused { model.resume() } else { model.pause() } } label: {
                        Label(model.paused ? "返回实时窗口" : "截取画面",systemImage:model.paused ? "arrow.uturn.backward" : "camera")
                    }.disabled(model.busy).font(.system(size:12)).buttonStyle(.bordered)
                }
            }.padding(.horizontal,14).padding(.vertical,10)
            Divider()
            if model.picking {
                ScrollView {
                    VStack(spacing:0) {
                        if model.targets.isEmpty { emptyState }
                        ForEach(model.targets) { item in
                            Button { Task { await model.choose(item) } } label: { ScreenTargetRow(target:item) }.disabled(model.busy)
                            Divider()
                        }
                    }.padding(18)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            if model.snapshots.isEmpty { emptyState }
                            ForEach(Array(model.snapshots.enumerated()),id:\.element.id) { index,shot in
                                VStack(alignment:.leading,spacing:10) {
                                    HStack {
                                        Text("画面 \(index+1)").font(.system(size:12,weight:.medium))
                                        Text(shot.capturedAt.map { $0.formatted(date:.omitted,time:.standard) } ?? "时间未知").font(.system(size:12)).foregroundStyle(IslandStyle.secondary)
                                        Spacer()
                                        Text(model.paused && model.current?.id == shot.id ? "已冻结" : "已截取").font(.system(size:12)).foregroundStyle(IslandStyle.secondary)
                                        ToolButton(title:"删除画面 \(index+1)",symbol:"trash") { pendingDelete = shot }.disabled(model.busy)
                                    }
                                    GeometryReader { geometry in
                                        ReviewPreview(model:model,shot:shot)
                                            .frame(width:geometry.size.width,height:geometry.size.height)
                                    }.frame(height:min(205,462 * shot.image.size.height / max(1,shot.image.size.width)))
                                        .clipShape(RoundedRectangle(cornerRadius:6))
                                        .help("在冻结画面上拖动框选；点击编号标记编辑意见")
                                        .accessibilityLabel("画面 \(index+1)，冻结画面及编号标记")
                                    ForEach(model.regions.filter{$0.snapshotID == shot.id}) { region in
                                        Button { model.select(region.id) } label: {
                                            HStack(alignment:.top,spacing:10) {
                                                Text("\(region.number)").font(.system(size:12,weight:.medium)).frame(width:22,height:22).background(.blue,in:Circle())
                                                Text(region.feedback.isEmpty ? "添加意见" : region.feedback).font(.system(size:14)).fixedSize(horizontal:false,vertical:true)
                                                Spacer(minLength:0)
                                                if model.selectedID == region.id { Image(systemName:"pencil").font(.system(size:12)).accessibilityLabel("正在编辑") }
                                            }.padding(8).frame(maxWidth:.infinity,alignment:.leading)
                                                .background(model.selectedID == region.id ? Color.white.opacity(0.06) : .clear,in:RoundedRectangle(cornerRadius:6))
                                        }.id(region.id)
                                    }
                                    if !model.regions.contains(where:{$0.snapshotID == shot.id}) {
                                        Label("在冻结画面上框选标记",systemImage:"viewfinder").font(.system(size:12)).foregroundStyle(IslandStyle.secondary)
                                    }
                                }
                            }
                        }.padding(16)
                    }.onChange(of:model.selectedID) { if let id = model.selectedID { proxy.scrollTo(id,anchor:.bottom) } }
                }
                if let id = model.selectedID, let region = model.regions.first(where:{$0.id == id}) {
                    Divider()
                    HStack {
                        Label("意见 \(region.number)",systemImage:"pencil").font(.system(size:12))
                        Spacer()
                        if voice.voiceActive { Text("语音处理中").font(.system(size:12)).foregroundStyle(IslandStyle.secondary) }
                        ToolButton(title:voice.dictating ? "结束语音" : "开始语音意见",symbol:voice.dictating ? "stop.circle.fill" : "mic") { voice.toggleVoice() }
                            .disabled(model.busy || voice.voicePreparing || voice.voiceFinishing || voice.unavailableReason != nil)
                        ToolButton(title:"删除选中标记",symbol:"trash") { Task { await model.deleteSelectedRegion() } }
                            .disabled(model.busy).keyboardShortcut(.delete,modifiers:[.command])
                    }.padding(.horizontal,16).padding(.top,8)
                    TextEditor(text:$voice.draft).font(.system(size:14)).frame(height:62).scrollContentBackground(.hidden)
                        .padding(8).background(.white.opacity(0.04),in:RoundedRectangle(cornerRadius:6)).padding(.horizontal,16).disabled(voice.voiceActive)
                    StatusDetails(title:voice.unavailableReason != nil ? "语音暂不可用" : (voice.voiceActive ? "语音状态" : "文字或语音意见"),detail:voice.unavailableReason ?? voice.status)
                        .font(.system(size:12)).foregroundStyle(IslandStyle.secondary).padding(.horizontal,16).padding(.vertical,6)
                }
            }
            HStack(spacing:12) {
                if model.canUndo {
                    ToolButton(title:"撤销",symbol:"arrow.uturn.backward") { Task { await model.undoEdit() } }.disabled(model.busy).keyboardShortcut("z",modifiers:[.command])
                }
                Spacer()
                if !model.picking {
                    Button { model.finish() } label: { Label(model.copied ? "已复制" : "复制全部",systemImage:model.copied ? "checkmark" : "doc.on.doc") }
                        .buttonStyle(PrimaryActionStyle()).disabled(model.snapshots.isEmpty || model.busy)
                }
                Button("保存并关闭") { model.close() }.disabled(model.busy)
            }.font(.system(size:12)).padding(14)
            Divider()
            HStack {
                StatusDetails(title:model.busy ? "处理中" : (model.status.contains("失败") ? "操作未完成 · 查看详情" : (model.snapshots.isEmpty ? "尚未截取" : "本地批阅状态")),detail:model.status)
                Spacer()
                Button("查看本地批阅") { model.reveal() }.disabled(model.snapshots.isEmpty)
            }.font(.system(size:12)).foregroundStyle(IslandStyle.secondary).padding(14)
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top).buttonStyle(.plain).modifier(IslandSurface())
            .alert("删除截图及其意见？",isPresented:Binding(get:{pendingDelete != nil},set:{if !$0 {pendingDelete = nil}})) {
                Button("取消",role:.cancel) { pendingDelete = nil }
                Button("删除",role:.destructive) { if let shot = pendingDelete { Task { await model.deleteSnapshot(shot.id) } }; pendingDelete = nil }
            } message: { Text("删除后可撤销恢复截图和意见。") }
    }
    private var emptyState: some View {
        VStack(spacing:18) {
            HStack(spacing:18) { Image(systemName:"camera"); Image(systemName:"chevron.right"); Image(systemName:"viewfinder"); Image(systemName:"chevron.right"); Image(systemName:"pencil") }.font(.system(size:23))
            Text(model.picking ? "选择窗口开始批阅" : "截取画面，框选后添加意见").font(.system(size:14))
        }.foregroundStyle(IslandStyle.secondary).frame(maxWidth:.infinity).padding(.vertical,38)
    }
}

struct ReviewPreview: NSViewRepresentable {
    @ObservedObject var model:ReviewModel
    let shot:ReviewSnapshot
    func makeNSView(context:Context) -> ReviewCanvas { let view = ReviewCanvas(); view.showsTimestamp = false; return view }
    func updateNSView(_ view:ReviewCanvas,context:Context) { view.model = model; view.snapshot = shot; view.needsDisplay = true }
}
