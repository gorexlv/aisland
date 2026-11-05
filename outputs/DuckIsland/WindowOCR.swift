import Cocoa
import Combine
import ScreenCaptureKit
import SwiftUI

struct WindowOCRRecord: Identifiable { let id: UUID; let file: URL; var text: String; let date: Date }

@MainActor final class WindowOCRPanels {
    weak var session: WindowOCRSession?
    var reframeAction: (() -> Void)?
    private(set) var toolbar: NSPanel?
    private(set) var record: NSPanel?
    private var targetFrame: CGRect?
    private var toolbarScale: CGFloat?
    private var relative = CGPoint(x:0.88,y:0.78)
    private var workspaceVisible = true
    var desktopTop: CGFloat { NSScreen.screens.first?.frame.maxY ?? 0 }
    var orbAnchor: CGPoint { layout?.anchor ?? .zero }
    private var layout: ReviewOrbitLayout? { targetFrame.map { reviewOrbitLayout(target:$0,relative:relative) } }
    private func panel(_ frame:CGRect,level:Int) -> NSPanel {
        let p = IslandPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = false; p.hidesOnDeactivate = false
        p.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+level)
        p.collectionBehavior = [.fullScreenAuxiliary,.stationary,.ignoresCycle]
        p.animationBehavior = .none; p.isReleasedWhenClosed = false
        return p
    }
    func position(_ frame: CGRect) {
        workspaceVisible = true
        if frame != .zero { targetFrame = reviewScreenRect(frame,desktopTop:desktopTop) }
        refresh()
    }
    func moveOrb(to point: CGPoint) {
        guard let targetFrame else { return }
        let next = reviewOrbitLayout(target:targetFrame,relative:CGPoint(x:(point.x-targetFrame.minX)/max(1,targetFrame.width),y:(point.y-targetFrame.minY)/max(1,targetFrame.height)))
        relative = CGPoint(x:(next.anchor.x-targetFrame.minX)/max(1,targetFrame.width),y:(next.anchor.y-targetFrame.minY)/max(1,targetFrame.height))
        refresh()
    }
    private func orbitView(_ session: WindowOCRSession, _ layout: ReviewOrbitLayout) -> AnyView {
        AnyView(WindowOCROrbitView(session:session,voice:session.voice,reframeAction:reframeAction).scaleEffect(layout.scale,anchor:.topLeading).frame(width:layout.controls.width,height:layout.controls.height,alignment:.topLeading))
    }
    private func refresh() {
        guard let session, session.active, let layout else { toolbar?.orderOut(nil); record?.orderOut(nil); return }
        if toolbar == nil {
            let p = panel(layout.controls,level:4); p.title = "读屏呼吸灯"
            p.contentView = ReviewControlsHostingView(rootView:orbitView(session,layout)); toolbar = p; toolbarScale = layout.scale
        } else if toolbarScale != layout.scale, let host = toolbar?.contentView as? NSHostingView<AnyView> {
            host.rootView = orbitView(session,layout); toolbarScale = layout.scale
        }
        if record == nil {
            let p = panel(layout.preview,level:3); p.hasShadow = true; p.title = "读屏记录"
            p.contentView = ReviewControlsHostingView(rootView:WindowOCRRecordView(session:session)); record = p
        }
        toolbar?.setFrame(layout.controls,display:true); record?.setFrame(layout.preview,display:true)
        if workspaceVisible { record?.orderFrontRegardless(); toolbar?.orderFrontRegardless() }
    }
    func hideForWorkspace() { workspaceVisible = false; toolbar?.orderOut(nil); record?.orderOut(nil) }
    func close() {
        toolbar?.close(); toolbar = nil; toolbarScale = nil; record?.close(); record = nil
        targetFrame = nil; relative = CGPoint(x:0.88,y:0.78); workspaceVisible = true
    }
}

struct WindowOCROrbitView: View {
    @ObservedObject var session: WindowOCRSession
    @ObservedObject var voice: VoiceInput
    @ObservedObject private var live: MoLiveSession
    @ObservedObject private var reader: ScreenReader
    var reframeAction: (() -> Void)?
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragStart: (anchor:CGPoint, mouse:CGPoint)?
    @State private var recordsShown = false
    @GestureState private var isDragging = false
    init(session:WindowOCRSession,voice:VoiceInput,reframeAction:(() -> Void)? = nil) {
        self.session = session; self.voice = voice; self.live = session.live; self.reader = session.reader; self.reframeAction = reframeAction
    }
    private var hasText: Bool { !reader.text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty }
    private var ringColor: Color { colorScheme == .dark ? Color(red:0.69,green:0.86,blue:0.97) : Color(red:0.35,green:0.52,blue:0.68) }
    private func reframe() { if let reframeAction { reframeAction() } else { session.reframe() } }
    var body: some View {
        ZStack {
            Button { recordsShown.toggle() } label: {
                Image(systemName:"list.bullet.rectangle").font(.system(size:13,weight:.semibold))
                    .frame(width:28,height:28)
                    .foregroundStyle(colorScheme == .dark ? Color(red:0.77,green:0.93,blue:0.89) : Color(red:0.13,green:0.47,blue:0.39))
                    .background(colorScheme == .dark ? Color(red:0.18,green:0.27,blue:0.29) : Color(red:0.92,green:0.98,blue:0.96),in:Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9),lineWidth:1.5))
                    .shadow(color:.black.opacity(0.12),radius:3,y:2)
            }.accessibilityLabel("读屏记录，共 \(session.records.count) 条").help("读屏记录 · \(session.records.count) 条")
                .popover(isPresented:$recordsShown) { WindowOCRRecordList(session:session,reframe:reframe) }
                .position(x:37,y:105).zIndex(1)
            Button { reframe() } label: {
                MoOrb(ringColor:ringColor,busy:reader.busy,listening:voice.dictating || live.ready)
            }.disabled(reader.busy)
                .accessibilityLabel("重新框选识别区域").help("点击重新框选；拖动移动呼吸灯")
                .highPriorityGesture(DragGesture(minimumDistance:6).updating($isDragging) { _,state,_ in state = true }.onChanged { value in
                    let mouse = NSEvent.mouseLocation
                    if dragStart == nil { dragStart = (session.panels.orbAnchor,CGPoint(x:mouse.x-value.translation.width,y:mouse.y+value.translation.height)) }
                    if let origin = dragStart { session.panels.moveOrb(to:CGPoint(x:origin.anchor.x+mouse.x-origin.mouse.x,y:origin.anchor.y+mouse.y-origin.mouse.y)) }
                }.onEnded { _ in dragStart = nil })
                .onChange(of:isDragging) { if !isDragging { dragStart = nil } }
                .contextMenu {
                    Button("重新框选") { reframe() }.disabled(reader.busy)
                    Button("查看记录（\(session.records.count)）") { recordsShown = true }
                    Divider()
                    Button("结束并撤下") { Task { if !(await session.end()) { session.status = "修改未保存，请先保存或复制后再结束" } } }
                }.position(x:64,y:84)
            Button { session.setSpeakingEnabled(!session.speakingEnabled) } label: {
                Image(systemName:session.speakingEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size:13,weight:.semibold)).foregroundStyle(.white)
                    .frame(width:28,height:28)
                    .background(session.speakingEnabled ? Color(red:0.08,green:0.45,blue:0.94) : Color(red:0.30,green:0.35,blue:0.39),in:Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9),lineWidth:1.5))
            }.disabled(!session.speakingEnabled && !hasText)
                .help(!session.speakingEnabled && !hasText ? "请先框选识别文字" : (session.speakingEnabled ? "发言：可就识别文字与默默对话；点击切为静默" : "静默；点击开启发言"))
                .accessibilityLabel(session.speakingEnabled ? "发言模式，切换静默" : "静默模式，切换发言")
                .position(x:91,y:105)
        }.frame(width:128,height:124).buttonStyle(.plain)
    }
}

struct WindowOCRRecordList: View {
    @ObservedObject var session: WindowOCRSession
    let reframe: () -> Void
    var body: some View {
        VStack(alignment:.leading,spacing:0) {
            if session.records.isEmpty { Text("暂无记录").font(.system(size:12)).foregroundStyle(IslandStyle.secondary).padding(16) }
            else {
                ScrollView {
                    VStack(spacing:0) {
                        ForEach(session.records.reversed()) { record in
                            HStack(spacing:6) {
                                VStack(alignment:.leading,spacing:2) {
                                    Text(record.text.split(separator:"\n",omittingEmptySubsequences:true).first.map(String.init) ?? "（空）").font(.system(size:12)).lineLimit(1)
                                    Text(record.date.formatted(date:.omitted,time:.standard)).font(.system(size:10,design:.monospaced)).foregroundStyle(IslandStyle.secondary)
                                }
                                Spacer(minLength:4)
                                ToolButton(title:"复制",symbol:"doc.on.doc") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(record.text,forType:.string) }
                                ToolButton(title:"在 Finder 中显示",symbol:"folder") { NSWorkspace.shared.activateFileViewerSelecting([record.file]) }
                            }.padding(.horizontal,12).padding(.vertical,4)
                            Divider()
                        }
                    }
                }.frame(maxHeight:220)
            }
            Button("重新框选") { reframe() }.buttonStyle(PrimaryActionStyle()).padding(12).disabled(session.reader.busy)
        }.frame(width:300).modifier(IslandSurface())
    }
}

struct WindowOCRRecordView: View {
    @ObservedObject var session: WindowOCRSession
    @ObservedObject private var reader: ScreenReader
    @ObservedObject private var live: MoLiveSession
    init(session:WindowOCRSession) { self.session = session; reader = session.reader; live = session.live }
    var body: some View {
        VStack(alignment:.leading,spacing:6) {
            if !session.note.isEmpty { Text("意图：" + session.note).font(.system(size:11,weight:.medium)).foregroundStyle(IslandStyle.secondary).lineLimit(2) }
            TextEditor(text:$reader.text).font(.system(size:12)).scrollContentBackground(.hidden)
                .padding(4).background(Color.white.opacity(0.05),in:RoundedRectangle(cornerRadius:7)).frame(minHeight:40)
            HStack(spacing:6) {
                if reader.busy { ProgressView().controlSize(.mini) }
                Text(session.status.isEmpty ? reader.status : session.status).font(.system(size:10)).foregroundStyle(IslandStyle.secondary).lineLimit(2)
                Spacer(minLength:2)
                if reader.canRetrySave { Button("重试保存") { reader.save() }.buttonStyle(.plain).font(.system(size:11,weight:.medium)).foregroundStyle(Color.blue) }
                ToolButton(title:"复制",symbol:"doc.on.doc") { reader.copy() }.disabled(reader.text.isEmpty)
                ToolButton(title:"定位文件",symbol:"folder") { reader.reveal() }.disabled(reader.savedFile == nil)
            }
            if live.active {
                Divider()
                ScrollView {
                    VStack(alignment:.leading,spacing:4) {
                        ForEach(live.messages.suffix(6)) { message in
                            Text((message.role == "assistant" ? "默默：" : "你：") + message.text).font(.system(size:11)).foregroundStyle(message.role == "assistant" ? Color.white : IslandStyle.secondary).frame(maxWidth:.infinity,alignment:.leading)
                        }
                    }
                }.frame(maxHeight:60)
            }
        }.padding(10).buttonStyle(.plain).modifier(IslandSurface())
    }
}

@MainActor final class WindowOCRSession: ObservableObject {
    let reader: ScreenReader
    let live = MoLiveSession()
    let voice: VoiceInput
    var panels = WindowOCRPanels()
    @Published var active = false
    @Published var target: ScreenTarget?
    @Published var note = "" { didSet { reader.note = note } }
    @Published var records: [WindowOCRRecord] = []
    @Published var speakingEnabled = false
    @Published var status = ""
    var startLive: ((String) async -> Void)?
    var stopLive: (() async -> Void)?
    private var liveChain: Task<Void,Never>?
    private var tracking: Timer?
    private var trackingBusy = false
    private var token = UUID()
    private var statusLink: AnyCancellable?
    init(voice: VoiceInput, storageRoot: URL? = nil) {
        self.voice = voice; reader = ScreenReader(storageRoot:storageRoot)
        panels.session = self
        reader.onSaved = { [weak self] file, text in self?.saved(file,text) }
        statusLink = reader.$status.dropFirst().sink { [weak self] in self?.status = $0 }
    }
    var latestText: String { reader.text }
    func attach(_ item: ScreenTarget, note: String) async -> Bool {
        guard !active else { status = "请先结束当前读屏"; return false }
        let window: SCWindow
        do { window = try await resolveScreenWindow(item) } catch { status = error.localizedDescription; return false }
        token = UUID()
        target = item; self.note = note; active = true
        records = []; speakingEnabled = false
        tracking?.invalidate()
        tracking = Timer.scheduledTimer(withTimeInterval:0.8,repeats:true) { [weak self] _ in
            Task { @MainActor in await self?.track() }
        }
        panels.position(window.frame)
        reframe()
        return true
    }
    func reframe() { if let target { reader.select(target) } }
    private func saved(_ file: URL, _ text: String) {
        if reader.lastSaveWasResave, !records.isEmpty { records[records.count-1] = WindowOCRRecord(id:records[records.count-1].id,file:file,text:text,date:records[records.count-1].date) }
        else { records.append(WindowOCRRecord(id:UUID(),file:file,text:text,date:Date())) }
        if speakingEnabled { enqueueLive(restart:true) }
    }
    private func enqueue(_ op: @escaping @MainActor () async -> Void) {
        let previous = liveChain
        liveChain = Task { await previous?.value; await op() }
    }
    private func enqueueLive(restart: Bool) {
        enqueue { [weak self] in
            guard let self, self.speakingEnabled, let target = self.target else { return }
            let text = self.latestText
            guard !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { return }
            await self.stopNow()
            guard self.speakingEnabled else { return }
            let context = "OCR 识别文字（\(target.label)）：\n" + text
            if let startLive = self.startLive { await startLive(context) } else { await self.live.start(context:context,deviceID:self.voice.selectedInputID) }
        }
    }
    private func stopNow() async { if let stopLive { await stopLive() } else { await live.stop() } }
    private func stopLiveSerialized() async {
        enqueue { [weak self] in await self?.stopNow() }
        await liveChain?.value
    }
    func setSpeakingEnabled(_ on: Bool) {
        if on {
            guard target != nil, !latestText.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { status = "请先框选识别文字"; return }
            speakingEnabled = true; enqueueLive(restart:false)
        } else { speakingEnabled = false; enqueue { [weak self] in await self?.stopNow() } }
    }
    private func track() async {
        guard active, !trackingBusy, let target else { return }
        trackingBusy = true; defer { trackingBusy = false }
        let session = token
        do {
            let window = try await resolveScreenWindow(target)
            guard session == token, self.target == target else { return }
            let visible = (CGWindowListCopyWindowInfo(.optionOnScreenOnly,kCGNullWindowID) as? [[String:Any]] ?? []).contains { ($0[kCGWindowNumber as String] as? UInt32) == target.id }
            if visible { panels.position(window.frame) } else { panels.hideForWorkspace() }
        } catch {
            guard session == token, self.target == target else { return }
            speakingEnabled = false
            await stopLiveSerialized()
            guard session == token else { return }
            reader.cancel(); tracking?.invalidate(); tracking = nil
            status = "目标窗口已关闭，已有读屏记录仍可查看"
        }
    }
    func end() async -> Bool {
        if reader.dirty { reader.save() }
        if reader.dirty { return false }
        token = UUID(); tracking?.invalidate(); tracking = nil
        speakingEnabled = false
        await stopLiveSerialized()
        reader.reset(); panels.close()
        active = false; target = nil; note = ""; records = []; status = ""
        return true
    }
    func preserveForTermination() -> Bool { reader.preserveForTermination() }
}
