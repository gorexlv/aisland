import Cocoa
import SwiftUI

@MainActor final class ReviewPanels {
    weak var model: ReviewModel?
    var sidebar: NSPanel?
    var overlay: NSPanel?
    private(set) var conversation:NSPanel?
    private(set) var selectionOverlay: NSPanel?
    private(set) var toolbar: NSPanel?
    private(set) var glow: NSPanel?
    private(set) var completion: NSPanel?
    private(set) var history: NSPanel?
    private var completionLocalMonitor: Any?
    private var completionGlobalMonitor: Any?
    private var completionFocusObserver: NSObjectProtocol?
    private var historyDelegate: ReviewHistoryWindowDelegate?
    private var targetFrame: CGRect?
    private var toolbarScale: CGFloat?
    private var pickerRowCount: Int?
    private var reviewEscapeMonitor: Any?
    private var relative = CGPoint(x:0.88,y:0.78)
    private var editorRequested = false
    private var workspaceVisible = true
    private var highlights: [NSPanel] = []
    var islandExtraHeight: () -> CGFloat = { 0 }
    var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    var orbAnchor: CGPoint { layout?.anchor ?? .zero }
    private var layout: ReviewOrbitLayout? {
        guard let targetFrame else { return nil }
        let aspect: CGFloat = 1.5
        return reviewOrbitLayout(target:targetFrame,relative:relative,aspect:aspect)
    }
    init(model:ReviewModel) { self.model = model }
    private func panel(_ frame:CGRect,level:Int) -> NSPanel {
        let p = IslandPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.hidesOnDeactivate = false
        p.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+level)
        p.collectionBehavior = [.fullScreenAuxiliary,.stationary,.ignoresCycle]
        p.animationBehavior = .none; p.isReleasedWhenClosed = false
        return p
    }
    func showSidebar() {
        guard let model else { return }
        if model.historyPresented { sidebar?.orderOut(nil); return }
        if !model.picking, targetFrame != nil, !editorRequested {
            sidebar?.orderOut(nil); refreshChrome(); return
        }
        if sidebar == nil {
            let p = panel(sidebarFrame(),level:3)
            p.styleMask.insert(.resizable); p.minSize = NSSize(width:300,height:400)
            p.isMovableByWindowBackground = true; p.hasShadow = true
            p.contentView = NSHostingView(rootView:ReviewPanelContent(model:model)); sidebar = p
        }
        if model.picking {
            sidebar?.minSize = NSSize(width:300,height:90)
            sidebar?.styleMask.remove(.resizable)
            sidebar?.setFrame(targetPickerFrame(),display:true)
        } else {
            sidebar?.minSize = NSSize(width:300,height:400)
            sidebar?.styleMask.insert(.resizable)
        }
        if workspaceVisible { sidebar?.orderFrontRegardless() }
    }
    private func targetPickerFrame() -> CGRect {
        let screen = (NSApp.delegate as? AppDelegate)?.panel?.screen ?? NSScreen.main ?? NSScreen.screens.first
        let area = screen?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
        let size = CGSize(width:min(500,area.width-32),height:reviewPickerHeight(rowCount:pickerRowCount ?? ((model?.targets.count ?? 0)+1),availableHeight:area.height-32))
        return CGRect(x:area.midX-size.width/2,y:area.midY-size.height/2,width:size.width,height:size.height)
    }
    func resizeTargetPicker(rowCount:Int) {
        pickerRowCount = rowCount
        guard model?.picking == true else { return }
        sidebar?.setFrame(targetPickerFrame(),display:true)
    }
    func showTargetPicker() {
        workspaceVisible = true
        showSidebar()
        sidebar?.collectionBehavior.insert(.moveToActiveSpace)
        sidebar?.setFrame(targetPickerFrame(),display:true)
        sidebar?.makeKeyAndOrderFront(nil)
    }
    func showEditor() { editorRequested = true; showSidebar() }
    func positionSidebar(_ frame:CGRect) {
        workspaceVisible = true
        if frame != .zero {
            let next = reviewScreenRect(frame,desktopTop:desktopTop)
            if targetFrame == nil { editorRequested = false }
            targetFrame = next
        }
        showSidebar(); refreshChrome()
    }
    func moveOrb(to point:CGPoint) {
        guard let targetFrame else { return }
        let next = reviewOrbitLayout(target:targetFrame,relative:CGPoint(x:(point.x-targetFrame.minX)/max(1,targetFrame.width),y:(point.y-targetFrame.minY)/max(1,targetFrame.height)))
        relative = CGPoint(x:(next.anchor.x-targetFrame.minX)/max(1,targetFrame.width),y:(next.anchor.y-targetFrame.minY)/max(1,targetFrame.height))
        refreshChrome()
    }
    func refreshChrome() {
        guard let model, model.active, !model.picking, let targetFrame, let layout else {
            toolbar?.orderOut(nil); glow?.orderOut(nil); selectionOverlay?.orderOut(nil); return
        }
        if toolbar == nil {
            let p = panel(layout.controls,level:4); p.title = "批阅呼吸灯"
            p.contentView = ReviewControlsHostingView(rootView:AnyView(ReviewOrbitView(model:model,voice:model.voice).scaleEffect(layout.scale,anchor:.topLeading).frame(width:layout.controls.width,height:layout.controls.height,alignment:.topLeading)))
            toolbar = p; toolbarScale = layout.scale
        } else if toolbarScale != layout.scale, let host = toolbar?.contentView as? NSHostingView<AnyView> {
            host.rootView = AnyView(ReviewOrbitView(model:model,voice:model.voice).scaleEffect(layout.scale,anchor:.topLeading).frame(width:layout.controls.width,height:layout.controls.height,alignment:.topLeading))
            toolbarScale = layout.scale
        }
        toolbar?.setFrame(layout.controls,display:true)
        if model.paused {
            if glow == nil { let p = panel(targetFrame,level:2); p.ignoresMouseEvents = true; p.contentView = ReviewGlowView(); glow = p }
            glow?.setFrame(targetFrame,display:true); glow?.contentView?.needsDisplay = true
            selectionOverlay?.setFrame(targetFrame,display:true)
            overlay?.setFrame(layout.preview,display:true)
            if workspaceVisible { selectionOverlay?.orderFrontRegardless(); glow?.orderFrontRegardless(); overlay?.orderFrontRegardless() }
        } else { selectionOverlay?.orderOut(nil); glow?.orderOut(nil); overlay?.orderOut(nil) }
        if workspaceVisible { toolbar?.orderFrontRegardless() }
        if let completion { completion.setFrame(completionFrame(),display:true); if workspaceVisible && model.completed && !model.historyPresented { completion.orderFrontRegardless() } }
    }
    func detachTarget() {
        targetFrame = nil; editorRequested = false
        toolbar?.close(); toolbar = nil; toolbarScale = nil; glow?.close(); glow = nil; hideCompletionMenu()
    }
    private func sidebarFrame() -> CGRect {
        let area = NSScreen.main?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
        let width = min(sidebar?.frame.width ?? 360,area.width-16), height = min(sidebar?.frame.height ?? 560,area.height-16)
        return CGRect(x:area.maxX-width-8,y:area.maxY-height-8,width:width,height:height)
    }
    func showHighlights(_ targets:[ScreenTarget]) async {
        clearHighlights()
        guard let model else { return }
        for target in targets.reversed() {
            guard model.active,model.picking else { clearHighlights(); return }
            guard let window = try? await resolveScreenWindow(target) else { continue }
            guard model.active,model.picking else { clearHighlights(); return }
            let p = panel(reviewScreenRect(window.frame,desktopTop:desktopTop),level:1)
            let view = ReviewHighlight(frame:NSRect(origin:.zero,size:p.frame.size)); view.label = target.label
            view.choose = { [weak model] in Task { @MainActor in await model?.choose(target) } }
            p.contentView = view; p.orderFrontRegardless(); highlights.append(p)
        }
        sidebar?.orderFrontRegardless()
    }
    func clearHighlights() { highlights.forEach{$0.close()}; highlights = [] }
    func showConversation() {
        guard let model else { return }
        if model.paused, !model.historyPresented, let overlay {
            overlay.makeKeyAndOrderFront(nil); return
        }
        if conversation == nil {
            let anchor = orbAnchor
            let area = NSScreen.screens.first(where:{$0.frame.contains(anchor)})?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
            let frame = CGRect(x:min(max(anchor.x-190,area.minX),area.maxX-380),y:min(max(anchor.y-440,area.minY),area.maxY-420),width:380,height:420)
            let p = NSPanel(contentRect:frame,styleMask:[.titled,.closable,.resizable,.nonactivatingPanel],backing:.buffered,defer:false)
            p.title = "默默"; p.isReleasedWhenClosed = false; p.hidesOnDeactivate = false; p.minSize = NSSize(width:350,height:240)
            p.level = .floating; p.collectionBehavior = [.fullScreenAuxiliary,.stationary]
            p.contentView = ReviewControlsHostingView(rootView:MoConversationPanel(model:model,voice:model.voice,live:model.live))
            conversation = p
        }
        conversation?.makeKeyAndOrderFront(nil)
    }
    func showOverlay(_ shot:ReviewSnapshot) {
        guard let model else { return }
        if targetFrame == nil { targetFrame = reviewScreenRect(shot.frame,desktopTop:desktopTop) }
        guard let layout else { return }
        if selectionOverlay == nil {
            let p = panel(targetFrame!,level:1); p.title = "目标窗口批阅画布"; selectionOverlay = p
        }
        let canvas = ReviewCanvas(frame:CGRect(origin:.zero,size:targetFrame!.size))
        canvas.model = model; canvas.snapshot = shot; canvas.showsTimestamp = false; canvas.rendersMarkersOnly = false
        selectionOverlay?.contentView = canvas
        if overlay == nil { let p = panel(layout.preview,level:3); p.hasShadow = true; p.title = "Chat Messages"; overlay = p }
        if let selectedID = model.selectedID { model.recordTranscriptSelection(selectedID) }
        if !(overlay?.contentView is NSHostingView<MoConversationPanel>) { overlay?.contentView = ReviewControlsHostingView(rootView:MoConversationPanel(model:model,voice:model.voice,live:model.live)) }
        refreshChrome()
        selectionOverlay?.makeKeyAndOrderFront(nil)
        selectionOverlay?.makeFirstResponder(canvas)
        if reviewEscapeMonitor == nil {
            reviewEscapeMonitor = NSEvent.addLocalMonitorForEvents(matching:.keyDown) { [weak self] event in
                MainActor.assumeIsolated {
                    guard let self, let model = self.model, event.keyCode == 53,
                          event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty,
                          model.paused, !model.busy, !model.historyPresented,
                          [self.selectionOverlay,self.overlay,self.toolbar].compactMap({$0}).contains(where:{$0 === event.window}) else { return event }
                    if let editor = event.window?.firstResponder as? NSTextView, editor.hasMarkedText() { return event }
                    model.resume(); return nil
                }
            }
        }
    }
    func redraw() { (selectionOverlay?.contentView as? ReviewCanvas)?.updateInlineControls(); selectionOverlay?.contentView?.needsDisplay = true; overlay?.contentView?.needsDisplay = true; refreshChrome() }
    func hideOverlay() {
        if let reviewEscapeMonitor { NSEvent.removeMonitor(reviewEscapeMonitor) }; reviewEscapeMonitor = nil
        selectionOverlay?.close(); selectionOverlay = nil; overlay?.close(); overlay = nil; glow?.orderOut(nil) }
    private func completionFrame() -> CGRect {
        let anchor = orbAnchor
        let area = NSScreen.screens.first(where:{$0.frame.contains(anchor)})?.visibleFrame ?? NSScreen.main?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
        return CGRect(x:min(max(anchor.x-240,area.minX+8),area.maxX-276),y:min(max(anchor.y-170,area.minY+8),area.maxY-132),width:268,height:124)
    }
    func showCompletionMenu() {
        guard let model else { return }
        if completion == nil { let p = panel(completionFrame(),level:5); p.hasShadow = true; p.contentView = NSHostingView(rootView:ReviewCompletionView(model:model)); completion = p }
        if completionLocalMonitor == nil {
            let mask: NSEvent.EventTypeMask = [.leftMouseDown,.rightMouseDown,.otherMouseDown]
            completionLocalMonitor = NSEvent.addLocalMonitorForEvents(matching:mask) { [weak self] event in
                MainActor.assumeIsolated {
                    if let panel = self?.completion, event.window !== panel { self?.hideCompletionMenu() }
                }
                return event
            }
            completionGlobalMonitor = NSEvent.addGlobalMonitorForEvents(matching:mask) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideCompletionMenu() }
            }
            completionFocusObserver = NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:completion,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated { self?.hideCompletionMenu() }
            }
        }
        if workspaceVisible { completion?.makeKeyAndOrderFront(nil) }
    }
    func showHistory() {
        guard let model, model.historyPresented else { return }
        sidebar?.orderOut(nil); hideCompletionMenu()
        if history == nil {
            let screen = NSScreen.screens.first(where:{$0.frame.contains(orbAnchor)}) ?? NSScreen.main
            let area = screen?.visibleFrame ?? CGRect(x:0,y:0,width:1000,height:800)
            let width = min(1280,area.width-32), height = min(900,area.height-32)
            let p = NSPanel(contentRect:CGRect(x:area.midX-width/2,y:area.midY-height/2,width:width,height:height),styleMask:[.titled,.closable,.resizable],backing:.buffered,defer:false)
            p.title = "历史批阅"; p.minSize = CGSize(width:940,height:700); p.isReleasedWhenClosed = false
            p.level = .normal; p.isFloatingPanel = false; p.hidesOnDeactivate = false
            p.contentView = NSHostingView(rootView:ReviewHistoryView(model:model))
            let delegate = ReviewHistoryWindowDelegate(model:model); historyDelegate = delegate; p.delegate = delegate; history = p
        }
        history?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func hideHistory() {
        history?.close(); history = nil; historyDelegate = nil
        model?.historyPresented = false
    }
    func hideCompletionMenu() {
        if let completionLocalMonitor { NSEvent.removeMonitor(completionLocalMonitor) }
        if let completionGlobalMonitor { NSEvent.removeMonitor(completionGlobalMonitor) }
        if let completionFocusObserver { NotificationCenter.default.removeObserver(completionFocusObserver) }
        completionLocalMonitor = nil; completionGlobalMonitor = nil; completionFocusObserver = nil
        let panel = completion; completion = nil; panel?.close()
    }
    func hideForWorkspace() { workspaceVisible = false; conversation?.orderOut(nil); selectionOverlay?.orderOut(nil); overlay?.orderOut(nil); sidebar?.orderOut(nil); toolbar?.orderOut(nil); glow?.orderOut(nil); hideCompletionMenu() }
    func close() { conversation?.close(); conversation = nil; hideHistory(); clearHighlights(); hideOverlay(); sidebar?.close(); sidebar = nil; detachTarget(); relative = CGPoint(x:0.88,y:0.78); workspaceVisible = true }
}

func reviewToolbarFrame(_ target: CGRect, isPage: Bool, visibleFrame: CGRect? = nil) -> CGRect {
    let height: CGFloat = 30
    let width = max(1,min(target.width/2,visibleFrame?.width ?? target.width/2))
    var x = target.midX-width/2
    var y = target.minY-height
    if let visibleFrame {
        x = min(max(x,visibleFrame.minX),visibleFrame.maxX-width)
        // Use the inside bottom edge when the screen has no room below the target.
        if y < visibleFrame.minY { y = max(target.minY,visibleFrame.minY) }
        y = min(y,visibleFrame.maxY-height)
    }
    return CGRect(x:x,y:y,width:width,height:height)
}

func reviewRegionHeaderFrame(_ region: CGRect) -> CGRect {
    CGRect(x:region.minX,y:region.minY,width:region.width,height:min(28,region.height))
}

struct ReviewWindowControls: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var voice: VoiceInput
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing:6) {
                Button { model.toggleSinglePage() } label: {
                    if geometry.size.width >= 240 { Label(model.paused ? "退出单页" : "批阅",systemImage:model.paused ? "arrow.uturn.backward" : "viewfinder") }
                    else { Image(systemName:model.paused ? "arrow.uturn.backward" : "viewfinder").frame(width:22,height:22) }
                }.accessibilityLabel(model.paused ? "保存并退出单页批阅" : "开始单页批阅").disabled(model.busy)
                Spacer(minLength:0)
                if geometry.size.width >= 240, let hint = model.shortcutHint {
                    Text(hint).foregroundStyle(IslandStyle.secondary).help("全局快捷键：进入／退出单页批阅")
                    Spacer(minLength:0)
                }
                if geometry.size.width >= 140 {
                    ReviewCompactButton(title:"展开批阅列表",symbol:"sidebar.right") { model.panels.showSidebar() }
                    ReviewCompactButton(title:"保存并结束全部批阅",symbol:"xmark") { model.close() }.disabled(model.busy)
                } else {
                    Menu {
                        Button("展开批阅列表") { model.panels.showSidebar() }
                        Button("保存并结束全部批阅") { model.close() }.disabled(model.busy)
                    } label: { Image(systemName:"ellipsis") }.menuStyle(.borderlessButton).frame(width:16).help("更多批阅操作")
                }
            }.font(.system(size:11,weight:.medium)).padding(.horizontal,geometry.size.width >= 140 ? 8 : 3)
                .frame(maxWidth:.infinity,maxHeight:.infinity)
        }.buttonStyle(.plain).modifier(IslandSurface())
    }
}

struct ReviewCompactButton: View {
    let title: String
    let symbol: String
    var action: () -> Void
    var body: some View {
        Button(action:action) { Image(systemName:symbol).frame(width:22,height:22).contentShape(Rectangle()) }
            .help(title).accessibilityLabel(title)
    }
}

struct ReviewRegionControls: View {
    @ObservedObject var model: ReviewModel
    @ObservedObject var voice: VoiceInput
    let region: ReviewRegion
    private var selected: Bool { model.selectedID == region.id }
    var body: some View {
        GeometryReader { geometry in
            HStack(spacing:4) {
                Button("#\(region.number)") { model.select(region.id) }
                    .font(.system(size:11,weight:.semibold)).fixedSize().disabled(model.busy)
                    .accessibilityLabel("选择批阅 \(region.number)")
                Spacer(minLength:0)
                if geometry.size.width >= 100 {
                    HStack(spacing:5) {
                        if selected && (voice.voicePreparing || voice.voiceFinishing) { ProgressView().controlSize(.mini) }
                        if geometry.size.width >= 230 { Text(selected ? captureTitle : "录音").lineLimit(1) }
                        if selected && voice.dictating && geometry.size.width >= 180 {
                            ProgressView(value:Double(voice.inputLevel)).tint(.green).frame(width:30).accessibilityLabel("麦克风采集电平")
                        }
                        ReviewCompactButton(title:selected && voice.dictating ? "停止语音录入" : "为批阅 \(region.number) 录音",symbol:selected && voice.dictating ? "stop.fill" : "mic.fill") {
                            model.select(region.id,speak:true)
                        }.foregroundStyle(selected && voice.dictating ? Color.green : Color.white)
                            .disabled(model.busy || voice.voicePreparing || voice.voiceFinishing || voice.unavailableReason != nil)
                    }.help(captureDetail)
                }
                Spacer(minLength:0)
                ReviewCompactButton(title:"删除批阅框 \(region.number) 及对应意见",symbol:"xmark") {
                    Task { await model.closeRegion(region.id) }
                }.disabled(model.busy)
            }.font(.system(size:11)).padding(.horizontal,4).frame(maxWidth:.infinity,maxHeight:.infinity)
        }.foregroundStyle(.white).buttonStyle(.plain)
            .background(Color(red:0.12,green:0.14,blue:0.16).opacity(0.96),in:RoundedRectangle(cornerRadius:3))
    }
    private var captureTitle: String {
        if model.status.contains("失败") { return "保存失败" }
        if voice.voicePreparing { return "启动中…" }
        if voice.voiceFinishing { return "收尾中…" }
        if voice.dictating { return "正在录音" }
        if voice.needsVoicePermission { return "需要语音权限" }
        return "已暂停"
    }
    private var captureDetail: String {
        if model.status.contains("失败") { return model.status }
        if let reason = voice.unavailableReason { return reason }
        return selected ? (voice.draft.isEmpty ? voice.status : voice.draft) : "点击麦克风为这条批阅录音"
    }
}

struct ReviewSidebarDragHandle: NSViewRepresentable {
    func makeNSView(context:Context) -> NSView { DragView() }
    func updateNSView(_ view:NSView,context:Context) {}
    private final class DragView: NSView {
        override func mouseDown(with event:NSEvent) { window?.performDrag(with:event) }
        override func resetCursorRects() { addCursorRect(bounds,cursor:.openHand) }
    }
}

struct ReviewSidebarResizeHandle: NSViewRepresentable {
    func makeNSView(context:Context) -> NSView { ResizeView() }
    func updateNSView(_ view:NSView,context:Context) {}
    private final class ResizeView: NSView {
        private var initialFrame: CGRect = .zero
        private var initialMouse: CGPoint = .zero
        override func mouseDown(with event:NSEvent) {
            initialFrame = window?.frame ?? .zero; initialMouse = NSEvent.mouseLocation
        }
        override func mouseDragged(with event:NSEvent) {
            guard let window else { return }
            let point = NSEvent.mouseLocation
            let width = max(window.minSize.width,initialFrame.width+point.x-initialMouse.x)
            let height = max(window.minSize.height,initialFrame.height-point.y+initialMouse.y)
            window.setFrame(CGRect(x:initialFrame.minX,y:initialFrame.maxY-height,width:width,height:height),display:true)
        }
        override func resetCursorRects() { addCursorRect(bounds,cursor:.resizeLeftRight) }
        override func draw(_ dirtyRect:NSRect) {
            NSColor.secondaryLabelColor.setStroke()
            for offset in stride(from:CGFloat(4),through:12,by:4) {
                let line = NSBezierPath(); line.move(to:NSPoint(x:bounds.maxX-offset,y:2))
                line.line(to:NSPoint(x:bounds.maxX-2,y:offset)); line.lineWidth = 1; line.stroke()
            }
        }
    }
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
final class ReviewCanvas:NSView, NSTextFieldDelegate {
    weak var model: ReviewModel?
    var snapshot:ReviewSnapshot?
    var allowsRegionSelection = true
    var rendersMarkersOnly = false
    var showsTimestamp = true
    var showsRegionControls = false
    private var regionControls: [UUID:NSHostingView<ReviewRegionControls>] = [:]
    private var textFields: [UUID:NSTextField] = [:]
    private var closeTracking: NSTrackingArea?
    private var hoveredClose: UUID?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let closeTracking { removeTrackingArea(closeTracking) }
        guard allowsRegionSelection else { return }
        let area = NSTrackingArea(rect:.zero,options:[.mouseMoved,.mouseEnteredAndExited,.activeAlways,.inVisibleRect],owner:self,userInfo:nil)
        closeTracking = area; addTrackingArea(area)
    }
    override func mouseMoved(with event:NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        let next = model?.regions.last(where:{$0.snapshotID == snapshot?.id && closeRect(regionRect($0)).contains(point)})?.id
        if hoveredClose != next { hoveredClose = next; needsDisplay = true }
    }
    override func mouseExited(with event:NSEvent) { hoveredClose = nil; needsDisplay = true }
    private enum RegionDrag { case move, right, bottom, corner }
    private var regionDrag: (id:UUID,kind:RegionDrag,origin:CGRect,anchor:CGPoint,rect:CGRect)?
    private func regionRect(_ entry:ReviewRegion) -> CGRect {
        let rect = regionDrag?.id == entry.id ? regionDrag!.rect : entry.rect
        return CGRect(x:rect.minX*bounds.width,y:rect.minY*bounds.height,width:rect.width*bounds.width,height:rect.height*bounds.height)
    }
    private func voiceButtonRect(_ rect:CGRect) -> CGRect? {
        guard model?.inputMode == .audio, rect.width >= 90, rect.height >= 22 else { return nil }
        return CGRect(x:rect.midX-12,y:rect.minY,width:24,height:22)
    }
    private func closeRect(_ rect:CGRect) -> CGRect {
        CGRect(x:rect.maxX-min(20,rect.width/2),y:rect.minY,width:min(20,rect.width/2),height:min(22,rect.height))
    }
    private func dragKind(at point:CGPoint,rect:CGRect) -> RegionDrag? {
        let right = abs(point.x-rect.maxX) <= 5 && point.y >= rect.minY && point.y <= rect.maxY+5
        let bottom = abs(point.y-rect.maxY) <= 5 && point.x >= rect.minX && point.x <= rect.maxX+5
        if right && bottom { return .corner }
        if right { return .right }
        if bottom { return .bottom }
        if CGRect(x:rect.minX,y:rect.minY,width:min(38,rect.width/2),height:min(22,rect.height)).contains(point) { return .move }
        return nil
    }
    private func dragRegion(to point:CGPoint) {
        guard var drag = regionDrag, bounds.width > 0, bounds.height > 0 else { return }
        let dx = (point.x-drag.anchor.x)/bounds.width, dy = (point.y-drag.anchor.y)/bounds.height
        var rect = drag.origin
        switch drag.kind {
        case .move:
            rect.origin.x = min(max(0,rect.minX+dx),1-rect.width)
            rect.origin.y = min(max(0,rect.minY+dy),1-rect.height)
        case .right, .bottom, .corner:
            if drag.kind != .bottom { rect.size.width = min(1-rect.minX,max(min(48/bounds.width,1-rect.minX),rect.width+dx)) }
            if drag.kind != .right { rect.size.height = min(1-rect.minY,max(min(36/bounds.height,1-rect.minY),rect.height+dy)) }
        }
        drag.rect = rect; regionDrag = drag
        updateInlineControls(); needsDisplay = true
    }
    override func layout() { super.layout(); updateRegionControls(); updateInlineControls() }
    func updateInlineControls() {
        guard allowsRegionSelection, let model, let snapshot else { return }
        let entries = model.regions.filter { $0.snapshotID == snapshot.id && $0.isText == true }
        let ids = Set(entries.map(\.id))
        for id in Array(textFields.keys) where !ids.contains(id) { textFields.removeValue(forKey:id)?.removeFromSuperview() }
        for entry in entries {
            let field: NSTextField
            if let existing = textFields[entry.id] { field = existing }
            else {
                field = NSTextField(wrappingLabelWithString:entry.feedback)
                field.isBezeled = true; field.bezelStyle = .roundedBezel
                field.drawsBackground = true; field.backgroundColor = .textBackgroundColor
                field.font = .systemFont(ofSize:14); field.placeholderString = "输入意见…"
                field.identifier = NSUserInterfaceItemIdentifier(entry.id.uuidString)
                field.delegate = self; field.setAccessibilityLabel("文字意见 \(entry.number)")
                textFields[entry.id] = field; addSubview(field)
            }
            let rect = regionRect(entry)
            field.frame = CGRect(x:rect.minX+6,y:rect.minY+25,width:max(1,rect.width-12),height:max(1,rect.height-32))
            field.isEditable = model.inputMode == .text && !model.busy && !model.voice.voiceActive
            field.isSelectable = true
            if field.currentEditor() == nil { field.stringValue = entry.feedback }
        }
    }
    func controlTextDidBeginEditing(_ notification:Notification) {
        guard let field = notification.object as? NSTextField, let id = field.identifier.flatMap({UUID(uuidString:$0.rawValue)}) else { return }
        model?.focusTextOpinion(id)
    }
    func controlTextDidChange(_ notification:Notification) {
        guard let field = notification.object as? NSTextField, let id = field.identifier.flatMap({UUID(uuidString:$0.rawValue)}) else { return }
        model?.updateOpinion(id,text:field.stringValue)
    }
    func updateRegionControls() {
        guard showsRegionControls, let model, let snapshot else { return }
        let visible = model.regions.filter { $0.snapshotID == snapshot.id }
        let ids = Set(visible.map(\.id))
        for id in Array(regionControls.keys) where !ids.contains(id) { regionControls.removeValue(forKey:id)?.removeFromSuperview() }
        for region in visible {
            let rect = CGRect(x:region.rect.minX*bounds.width,y:region.rect.minY*bounds.height,width:region.rect.width*bounds.width,height:region.rect.height*bounds.height)
            guard rect.width >= 64, rect.height >= 22 else {
                regionControls.removeValue(forKey:region.id)?.removeFromSuperview(); continue
            }
            let root = ReviewRegionControls(model:model,voice:model.voice,region:region)
            let host: NSHostingView<ReviewRegionControls>
            if let existing = regionControls[region.id] { host = existing }
            else { host = NSHostingView(rootView:root); regionControls[region.id] = host; addSubview(host) }
            let frame = reviewRegionHeaderFrame(rect)
            if host.frame != frame { host.frame = frame }
        }
    }
    private var start:CGPoint?
    private var current:CGPoint?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    override func resetCursorRects() {
        guard allowsRegionSelection else { return }
        addCursorRect(bounds,cursor:.crosshair)
        for entry in model?.regions.filter({$0.snapshotID == snapshot?.id}) ?? [] {
            let rect = regionRect(entry)
            addCursorRect(CGRect(x:rect.maxX-5,y:rect.minY+22,width:10,height:max(1,rect.height-22)),cursor:.resizeLeftRight)
            addCursorRect(CGRect(x:rect.minX,y:rect.maxY-5,width:rect.width,height:10),cursor:.resizeUpDown)
            addCursorRect(CGRect(x:rect.minX,y:rect.minY,width:min(38,rect.width/2),height:min(22,rect.height)),cursor:.openHand)
            addCursorRect(closeRect(rect),cursor:.pointingHand)
            if let voiceRect = voiceButtonRect(rect) { addCursorRect(voiceRect,cursor:.pointingHand) }
        }
    }
    override func draw(_ dirtyRect:NSRect) {
        guard let shot = snapshot, let model else { return }
        shot.image.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        if showsTimestamp {
        let badge = NSRect(x:8,y:8,width:250,height:24)
        NSColor.black.withAlphaComponent(0.85).setFill(); badge.fill()
        let timestamp = shot.capturedAt.map { $0.formatted(date:.omitted,time:.standard) } ?? "未知（旧记录）"
        ("截取画面 · " + timestamp as NSString).draw(in:badge.insetBy(dx:6,dy:4),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
        }
        for region in model.regions where region.snapshotID == shot.id && !rendersMarkersOnly {
            let r = regionRect(region)
            let color = NSColor.systemBlue.withAlphaComponent(region.id == model.selectedID ? 1 : 0.75)
            color.withAlphaComponent(0.12).setFill(); r.fill()
            color.setStroke(); let path = NSBezierPath(rect:r); path.lineWidth = 3; path.stroke()
            if allowsRegionSelection {
                if let button = voiceButtonRect(r) {
                    let selected = model.selectedID == region.id
                    let recording = selected && model.voice.dictating
                    let pending = selected && (model.voice.voicePreparing || model.voice.voiceFinishing)
                    let tint: NSColor = recording ? .systemRed : .systemBlue
                    NSColor.controlBackgroundColor.withAlphaComponent(0.92).setFill()
                    NSBezierPath(roundedRect:button.insetBy(dx:1,dy:1),xRadius:7,yRadius:7).fill()
                    let symbol = pending ? "hourglass" : (recording ? "stop.fill" : "mic.fill")
                    NSImage(systemSymbolName:symbol,accessibilityDescription:recording ? "停止录音" : "开始录音")?
                        .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors:[tint]))?
                        .draw(in:button.insetBy(dx:5,dy:4),from:.zero,operation:.sourceOver,fraction:1,respectFlipped:true,hints:nil)
                }
                let close = closeRect(r)
                let hovered = hoveredClose == region.id
                let diameter = min(16,min(close.width,close.height)-2)
                let circle = CGRect(x:close.midX-diameter/2,y:close.midY-diameter/2,width:diameter,height:diameter)
                (hovered ? NSColor.systemRed.withAlphaComponent(0.15) : NSColor.controlBackgroundColor.withAlphaComponent(0.88)).setFill()
                NSBezierPath(ovalIn:circle).fill()
                (hovered ? NSColor.systemRed : NSColor.secondaryLabelColor).setStroke()
                let cross = NSBezierPath(); cross.lineWidth = 1.5; cross.lineCapStyle = .round
                let inset = diameter*0.32
                cross.move(to:CGPoint(x:circle.minX+inset,y:circle.minY+inset)); cross.line(to:CGPoint(x:circle.maxX-inset,y:circle.maxY-inset))
                cross.move(to:CGPoint(x:circle.maxX-inset,y:circle.minY+inset)); cross.line(to:CGPoint(x:circle.minX+inset,y:circle.maxY-inset)); cross.stroke()
                color.setFill()
                CGRect(x:r.maxX-2,y:r.midY-7,width:4,height:min(14,r.height)).fill()
                CGRect(x:r.midX-7,y:r.maxY-2,width:min(14,r.width),height:4).fill()
            }
            if regionControls[region.id] == nil {
                let badge = NSRect(x:r.minX,y:r.minY,width:min(32,r.width/2),height:min(22,r.height))
                color.setFill(); badge.fill()
                ("#\(region.number)" as NSString).draw(in:badge.insetBy(dx:3,dy:3),withAttributes:[.font:NSFont.boldSystemFont(ofSize:12),.foregroundColor:NSColor.white])
                if model.selectedID == region.id, model.voice.voiceActive, r.width >= 48 {
                    let indicator = NSRect(x:badge.maxX+5,y:r.minY+6,width:10,height:10)
                    NSColor.systemRed.setFill(); NSBezierPath(ovalIn:indicator).fill()
                    NSColor.white.setStroke(); let outline = NSBezierPath(ovalIn:indicator); outline.lineWidth = 1.5; outline.stroke()
                }
            }
        }
        if let start, let current, let selection = reviewSelection(start,current,size:bounds.size) {
            let r = NSRect(x:selection.minX*bounds.width,y:selection.minY*bounds.height,width:selection.width*bounds.width,height:selection.height*bounds.height)
            NSColor.systemBlue.setStroke(); let path = NSBezierPath(rect:r); path.lineWidth=2; path.setLineDash([5,3],count:2,phase:0); path.stroke()
        }
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 53, event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty {
            model?.resume(); return
        }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" {
            Task { await model?.undoEdit() }; return
        }
        if event.modifierFlags.contains(.command), event.keyCode == 51 {
            Task { await model?.deleteSelectedRegion() }; return
        }
        super.keyDown(with:event)
    }
    override func mouseDown(with event:NSEvent) { guard allowsRegionSelection, model?.paused == true, model?.current?.id == snapshot?.id, model?.busy == false else { return }; window?.makeFirstResponder(self)
        let point = convert(event.locationInWindow,from:nil)
        for entry in (model?.regions.filter { $0.snapshotID == snapshot?.id } ?? []).reversed() {
            let rect = regionRect(entry)
            if voiceButtonRect(rect)?.contains(point) == true {
                guard model?.voice.voicePreparing == false, model?.voice.voiceFinishing == false else { return }
                model?.select(entry.id,speak:true); return
            }
            if closeRect(rect).contains(point) {
                Task { await model?.closeRegion(entry.id) }; return
            }
            if let kind = dragKind(at:point,rect:rect) {
                regionDrag = (entry.id,kind,entry.rect,point,entry.rect); return
            }
            if rect.contains(point) { break }
        }
        start = point; current = start
    }
    override func mouseDragged(with event:NSEvent) {
        let point = convert(event.locationInWindow,from:nil)
        if regionDrag != nil { dragRegion(to:point); return }
        current = point; needsDisplay = true
    }
    override func mouseUp(with event:NSEvent) {
        if regionDrag != nil {
            dragRegion(to:convert(event.locationInWindow,from:nil))
            let drag = regionDrag!; regionDrag = nil
            if drag.rect == drag.origin { model?.select(drag.id) }
            else { model?.updateRegionRect(drag.id,rect:drag.rect) }
            updateInlineControls(); needsDisplay = true; window?.invalidateCursorRects(for:self)
            return
        }
        guard let start, let model else { return }
        let end = convert(event.locationInWindow,from:nil)
        if let rect = reviewSelection(start,end,size:bounds.size) {
            if model.inputMode == .text {
                if let id = model.addTextRegion(rect,canvasSize:bounds.size) {
                    updateInlineControls(); window?.makeKey(); window?.makeFirstResponder(textFields[id])
                }
            } else { model.addRegion(rect) }
        }
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
                Label("截图批阅",systemImage:"line.3.horizontal").font(.system(size:14,weight:.semibold)).padding(.vertical,4).overlay(ReviewSidebarDragHandle()).help("拖动标题移动批阅列表")
                Spacer()
                ToolButton(title:"最近记录",symbol:"clock.arrow.circlepath") { RecordWindows.shared.show() }
                if model.recoveryFolder != nil && model.snapshots.isEmpty {
                    ToolButton(title:"恢复最近一次批阅",symbol:"arrow.counterclockwise") { model.restoreLatest() }.disabled(model.busy)
                }
                ToolButton(title:"关闭批阅并保存在本地",symbol:"xmark") { model.close() }.disabled(model.busy)
            }.padding(14)
            Divider()
            HStack {
                Text(model.target?.label ?? "选择窗口").font(.system(size:12)).foregroundStyle(IslandStyle.secondary).lineLimit(2).help(model.target?.label ?? "选择窗口")
                Spacer(minLength:8)
                if model.busy { ProgressView().controlSize(.small) }
                if model.picking {
                    ToolButton(title:"重新扫描窗口",symbol:"arrow.clockwise") { model.refreshPicker() }.disabled(model.busy)
                } else {
                    Button { model.toggleSinglePage() } label: {
                        Label(model.paused ? "返回实时窗口" : "截取画面",systemImage:model.paused ? "arrow.uturn.backward" : "camera")
                    }.disabled(model.busy).font(.system(size:12)).buttonStyle(.bordered)
                }
            }.padding(.horizontal,14).padding(.vertical,10)
            Divider()
            if model.picking {
                ScrollView {
                    VStack(spacing:0) {
                        Button { model.close() } label: {
                            Label("退出批阅",systemImage:"rectangle.portrait.and.arrow.right")
                                .frame(maxWidth:.infinity,alignment:.leading).padding(.vertical,12)
                        }.disabled(model.busy).help("保存批阅并解除目标窗口绑定")
                        Divider()
                        if model.targets.isEmpty { emptyState }
                        ForEach(model.targets) { item in
                            Button { Task { await model.choose(item) } } label: {
                                HStack { ScreenTargetRow(target:item); if model.target?.id == item.id { Image(systemName:"checkmark.circle.fill").foregroundStyle(.green).help("当前绑定") } }
                            }.disabled(model.busy)
                            Divider()
                        }
                    }.padding(18)
                }
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment:.leading,spacing:16) {
                            if !model.intentNote.isEmpty { Text("意图：" + model.intentNote).font(.system(size:12)).foregroundStyle(IslandStyle.secondary).fixedSize(horizontal:false,vertical:true) }
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
                                    }.aspectRatio(shot.image.size,contentMode:.fit).frame(maxHeight:205)
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
                if model.picking {
                    Button("关闭") { model.close() }.disabled(model.busy)
                } else {
                    Button("完成并处理") { model.completeReview() }.disabled(model.busy || model.snapshots.isEmpty)
                        .help("完成批阅后选择 Notes、复制或 Codex")
                }
            }.font(.system(size:12)).padding(14)
            Divider()
            HStack {
                StatusDetails(title:model.busy ? "处理中" : (model.status.contains("失败") ? "操作未完成 · 查看详情" : (model.snapshots.isEmpty ? "尚未截取" : "本地批阅状态")),detail:model.status)
                Spacer()
                Button("查看本地批阅") { model.reveal() }.disabled(model.snapshots.isEmpty)
            }.font(.system(size:12)).foregroundStyle(IslandStyle.secondary).padding(14)
        }.frame(maxWidth:.infinity,maxHeight:.infinity,alignment:.top).buttonStyle(.plain).modifier(IslandSurface())
            .overlay(alignment:.bottomTrailing) { ReviewSidebarResizeHandle().frame(width:18,height:18).help("拖动调整批阅列表大小") }
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
