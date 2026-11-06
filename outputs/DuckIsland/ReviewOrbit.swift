import Cocoa
import SwiftUI
import AVFoundation

struct ReviewOrbitLayout {
    let anchor: CGPoint
    let controls: CGRect
    let preview: CGRect
    let scale: CGFloat
}
func reviewOrbitLayout(target: CGRect, relative: CGPoint, aspect: CGFloat = 1.5) -> ReviewOrbitLayout {
    let scale = max(0.1,min(1,target.width/128,target.height/300))
    let minX = target.minX+64*scale, maxX = target.maxX-64*scale
    let minY = target.minY+min(168*scale,max(40*scale,target.height-84*scale))
    let maxY = target.maxY-84*scale
    let anchor = CGPoint(x:min(max(target.minX+relative.x*target.width,minX),maxX),y:min(max(target.minY+relative.y*target.height,minY),maxY))
    let safeAspect = aspect.isFinite && aspect > 0 ? aspect : 1.5
    let maxHeight = max(1,min(240,anchor.y-target.minY-54*scale))
    let width = max(1,min(350,target.width-24*scale,maxHeight*safeAspect))
    let height = width/safeAspect
    let x = anchor.x < target.midX ? target.minX+12*scale : target.maxX-12*scale-width
    return ReviewOrbitLayout(anchor:anchor,controls:CGRect(x:anchor.x-64*scale,y:anchor.y-40*scale,width:128*scale,height:124*scale),preview:CGRect(x:x,y:anchor.y-42*scale-height,width:width,height:height),scale:scale)
}

final class ReviewGlowView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.saveGraphicsState()
        let color = NSColor(calibratedRed:0.20,green:0.88,blue:0.72,alpha:1)
        let shadow = NSShadow(); shadow.shadowColor = color.withAlphaComponent(0.8); shadow.shadowBlurRadius = 18; shadow.shadowOffset = .zero; shadow.set()
        color.setStroke()
        let path = NSBezierPath(roundedRect:bounds.insetBy(dx:4,dy:4),xRadius:10,yRadius:10); path.lineWidth = 3; path.stroke()
        NSGraphicsContext.restoreGraphicsState()
        color.withAlphaComponent(0.17).setStroke()
        for inset in stride(from:CGFloat(7),through:19,by:3) {
            let line = NSBezierPath(roundedRect:bounds.insetBy(dx:inset,dy:inset),xRadius:8,yRadius:8); line.lineWidth = 2; line.stroke()
        }
    }
}

struct ReviewOrbitView: View {
    @ObservedObject private var live: MoLiveSession
    init(model:ReviewModel,voice:VoiceInput) {
        self.model = model; self.voice = voice; self.live = model.live; self.summary = model.liveSummary
    }
    @ObservedObject private var summary:MoLiveSummary
    @ObservedObject var model: ReviewModel
    @ObservedObject var voice: VoiceInput
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @State private var dragStart: (anchor:CGPoint, mouse:CGPoint)?
    @GestureState private var isDragging = false
    private var green: Color { colorScheme == .dark ? Color(red:0.27,green:0.93,blue:0.78) : Color(red:0.07,green:0.60,blue:0.48) }
    private var ringColor: Color { model.paused ? green : (colorScheme == .dark ? Color(red:0.69,green:0.86,blue:0.97) : Color(red:0.35,green:0.52,blue:0.68)) }
    var body: some View {
        ZStack {
            if !model.snapshots.isEmpty {
                Button { model.completeReview() } label: {
                    Image(systemName:"square.and.pencil").font(.system(size:13,weight:.semibold))
                        .frame(width:28,height:28)
                        .foregroundStyle(colorScheme == .dark ? Color(red:0.77,green:0.93,blue:0.89) : Color(red:0.13,green:0.47,blue:0.39))
                        .background(colorScheme == .dark ? Color(red:0.18,green:0.27,blue:0.29) : Color(red:0.92,green:0.98,blue:0.96),in:Circle())
                        .overlay(Circle().stroke(.white.opacity(0.9),lineWidth:1.5))
                        .shadow(color:.black.opacity(0.12),radius:3,y:2)
                }.disabled(model.busy)
                    .accessibilityLabel("Mo 的批阅 · 完成并查看历史，共 \(model.snapshots.count) 张截图")
                    .help("Mo 正在批阅 · \(model.snapshots.count) 张截图 · 点击完成并查看历史")
                    .position(x:37,y:105).zIndex(1)
            }
            Button { model.toggleSinglePage() } label: {
                MoOrb(ringColor:ringColor,busy:model.busy,activity:{ model.activityState })
            }.disabled(model.busy || model.historyPresented)
                .accessibilityLabel(model.paused ? "退出批阅模式" : "进入批阅模式并截图")
                .help("点击进入／退出批阅；拖动移动呼吸灯 · \(model.shortcutHint ?? "")")
                .highPriorityGesture(DragGesture(minimumDistance:6).updating($isDragging) { _,state,_ in state = true }.onChanged { value in
                    let mouse = NSEvent.mouseLocation
                    if dragStart == nil { dragStart = (model.panels.orbAnchor,CGPoint(x:mouse.x-value.translation.width,y:mouse.y+value.translation.height)) }
                    if let origin = dragStart { model.panels.moveOrb(to:CGPoint(x:origin.anchor.x+mouse.x-origin.mouse.x,y:origin.anchor.y+mouse.y-origin.mouse.y)) }
                }.onEnded { _ in dragStart = nil })
                .onChange(of:isDragging) { if !isDragging { dragStart = nil } }
                .contextMenu {
                    Button(model.inputMode == .audio ? "切换文字框选" : "切换语音框选") { Task { await model.setInputMode(model.inputMode == .audio ? .text : .audio) } }.disabled(model.busy || live.active)
                    Button("截取新画面") { model.pause() }.disabled(!model.canSwitchSnapshots)
                    Button("完成并查看历史（\(model.snapshots.count)）") { model.completeReview() }.disabled(model.busy || model.snapshots.isEmpty)
                    if model.snapshots.isEmpty { Button("恢复最近批阅") { model.onRestoreRequest?() }.disabled(model.busy) }
                    Divider()
                    Button("保存并关闭批阅") { model.close() }.disabled(model.busy)
                }.position(x:64,y:84)
            Button { model.setSpeakingEnabled(!model.speakingEnabled) } label: {
                Image(systemName:model.speakingEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.system(size:13,weight:.semibold)).foregroundStyle(.white)
                    .frame(width:28,height:28)
                    .background(model.speakingEnabled ? Color(red:0.08,green:0.45,blue:0.94) : Color(red:0.30,green:0.35,blue:0.39),in:Circle())
                    .overlay(Circle().stroke(.white.opacity(0.9),lineWidth:1.5))
            }.disabled(model.busy || model.historyPresented)
                .help(model.speakingEnabled ? "发言：呼唤默默或提问可对话；点击切为静默" : "静默：只听写记录，不回复；点击开启发言")
                .accessibilityLabel(model.speakingEnabled ? "发言模式，切换静默" : "静默模式，切换发言")
                .position(x:91,y:105)



        }.frame(width:128,height:124).buttonStyle(.plain)
    }
}

struct MoOrb: View {
    let ringColor: Color
    let busy: Bool
    let activity:() -> MoActivityState
    init(ringColor:Color,busy:Bool,activity:@escaping () -> MoActivityState) {
        self.ringColor = ringColor; self.busy = busy; self.activity = activity
    }
    // Preserve the call used by the separately merged OCR toolbar.
    init(ringColor:Color,busy:Bool,listening:Bool) {
        self.init(ringColor:ringColor,busy:busy,activity:{
            MoActivityState.resolve([MoActivity(id:"ocr",kind:listening ? .listening : busy ? .reading : .reviewing,title:listening ? "正在聆听" : busy ? "正在读屏" : "读屏就绪",target:.reader)])
        })
    }
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        TimelineView(.animation(minimumInterval:reduceMotion ? 1 : 1/30)) { context in
            let state = activity()
            let time = context.date.timeIntervalSinceReferenceDate
            let phase = reduceMotion ? 0.5 : (sin(time*2.5)+1)/2
            ZStack {
                Circle().stroke(ringColor.opacity(0.25+phase*0.40),lineWidth:7).frame(width:62,height:62).blur(radius:4).scaleEffect(1+phase*0.12)
                Circle().stroke(ringColor.opacity(0.25),lineWidth:1).frame(width:72,height:72)
                Circle().trim(from:0,to:0.25).stroke(ringColor,style:StrokeStyle(lineWidth:3,lineCap:.round)).frame(width:66,height:66)
                    .rotationEffect(.degrees(reduceMotion ? -60 : time.truncatingRemainder(dividingBy:5)*72))
                Circle().stroke(ringColor.opacity(0.7+phase*0.3),lineWidth:2).frame(width:62,height:62)
                Circle().fill(colorScheme == .dark ? Color(red:0.16,green:0.23,blue:0.30) : Color(red:0.14,green:0.18,blue:0.23)).frame(width:58,height:58)
                VStack(spacing:1) {
                    MoActivityAvatar(state:state,size:40)
                        .frame(width:40,height:40)
                        .offset(y:reduceMotion ? 0 : sin(time*1.8)*0.6)
                    Text("Mo").font(.system(size:9,weight:.semibold,design:.rounded)).foregroundStyle(.white)
                }.accessibilityHidden(true)
                if busy { ProgressView().controlSize(.mini).offset(x:20,y:-20) }
            }
        }.frame(width:76,height:76).contentShape(Circle())
    }
}


final class ReviewControlsHostingView<Content:View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
}

struct ReviewRecordingIndicator: View {
    @ObservedObject var voice: VoiceInput
    let reduceMotion: Bool
    var mode: ReviewInputMode = .audio
    private var color: Color {
        voice.voiceActive ? Color(red:0.92,green:0.14,blue:0.24) :
        (mode == .audio ? Color(red:0.08,green:0.45,blue:0.94) : Color(red:0.57,green:0.25,blue:0.87))
    }
    var body: some View {
        TimelineView(.animation(minimumInterval:1/24,paused:reduceMotion || !voice.voiceActive)) { context in
            let phase = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate*5)+1)/2
            ZStack {
                Circle().fill(color.opacity(0.28)).frame(width:36,height:36)
                Circle().fill(color).frame(width:32,height:32)
                    .overlay(Circle().stroke(.white.opacity(0.95),lineWidth:2))
                    .shadow(color:.black.opacity(0.25),radius:3,y:1)
                if voice.voicePreparing || voice.voiceFinishing {
                    ProgressView().controlSize(.mini).tint(.white)
                } else {
                    Image(systemName:mode == .audio ? "mic.fill" : "textformat")
                        .font(.system(size:16,weight:.bold)).foregroundStyle(.white)
                    if voice.dictating {
                        Circle().stroke(.red.opacity(0.9-phase*0.5),lineWidth:2).frame(width:35,height:35)
                        HStack(spacing:1.5) {
                            ForEach(0..<3) { i in
                                Capsule().fill(.white).frame(width:2,height:3+Double(voice.inputLevel)*7*(0.65+0.35*sin(context.date.timeIntervalSinceReferenceDate*9+Double(i)*1.7)))
                            }
                        }.padding(3).background(.red,in:Capsule()).offset(x:10,y:10)
                    }
                }
            }.frame(width:36,height:36).contentShape(Circle())
        }
    }
}

struct ReviewLiveTranscript: View {
    @State private var summaryPresented = false
    @ObservedObject var model: ReviewModel
    @ObservedObject var voice: VoiceInput
    private var records: [ReviewTranscriptRecord] { model.transcriptFeed.filter { record in model.regions.contains(where:{$0.id == record.regionID}) } }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:6) {
                Image(systemName:voice.voiceActive ? "waveform" : "text.alignleft").foregroundStyle(voice.voiceActive ? Color.red : .secondary)
                Text("Live Transcript").font(.system(size:12,weight:.semibold))
                Spacer()
                #if !APP_STORE
                Button {
                    summaryPresented = true
                    if model.aiSummary.isEmpty { model.summarizeReview() }
                } label: { Image(systemName:"sparkles") }.buttonStyle(.plain).help("AI Summary / CleanUp · 使用 Codex 整理转写")
                    .popover(isPresented:$summaryPresented) { ReviewAISummaryView(model:model) }
                #endif
                Menu {
                    Button { model.changeInputDevice(nil) } label: {
                        Label("系统默认输入",systemImage:voice.selectedInputID == nil ? "checkmark" : "mic")
                    }
                    Divider()
                    ForEach(voice.inputDevices) { device in
                        Button { model.changeInputDevice(device.id) } label: {
                            Label(device.name,systemImage:voice.selectedInputID == device.id ? "checkmark" : "mic")
                        }
                    }
                } label: { Image(systemName:"mic.badge.plus") }
                    .menuStyle(.borderlessButton).fixedSize().help("切换音频输入设备 · \(voice.inputDeviceName)")
                    .disabled(model.busy || model.live.active || voice.voicePreparing || voice.voiceFinishing)
                if voice.voicePreparing || voice.voiceFinishing { ProgressView().controlSize(.mini) }
                else if voice.dictating { Circle().fill(.red).frame(width:6,height:6) }
            }.padding(.horizontal,12).padding(.vertical,10)
            HStack(spacing:7) {
                Image(systemName:"mic").font(.system(size:10))
                Text(voice.inputDeviceName).font(.system(size:10)).lineLimit(1).help(voice.selectedInputID == nil ? "跟随系统默认输入" : "使用指定麦克风")
                Spacer(minLength:2)
                ProgressView(value:Double(voice.inputLevel)).tint(.green).frame(width:48).accessibilityLabel("麦克风输入电平")
            }.foregroundStyle(.secondary).padding(.horizontal,12).padding(.bottom,7)
            if voice.lastError != nil || voice.status.contains("未收到音频") || voice.needsVoicePermission {
                Text(voice.status).font(.system(size:10)).foregroundStyle(.orange).frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,12).padding(.bottom,7)
            }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:8) {
                        ForEach(records) { record in
                            if let region = model.regions.first(where:{$0.id == record.regionID}) {
                                let active = record.id == records.last?.id && region.id == model.selectedID
                                VStack(alignment:.leading,spacing:6) {
                                    HStack {
                                        Button { model.select(region.id) } label: { Text("#\(region.number)").font(.system(size:11,weight:.bold)) }.buttonStyle(.plain).disabled(model.busy)
                                        Text(reviewTranscriptTime(record.createdAt)).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary)
                                        Spacer()
                                        if active { Image(systemName:voice.dictating ? "waveform" : "circle.fill").font(.system(size:8)).foregroundStyle(voice.dictating ? Color.red : Color.accentColor) }
                                    }
                                    Text(record.text.isEmpty ? (active ? (voice.unavailableReason ?? (model.inputMode == .text ? "等待文字输入…" : "等待语音输入…")) : "暂无转写") : record.text)
                                        .font(.system(size:12)).foregroundStyle(record.text.isEmpty ? .secondary : .primary)
                                        .frame(maxWidth:.infinity,alignment:.leading).textSelection(.enabled)
                                }.padding(9).background(active ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:8))
                                    .overlay(RoundedRectangle(cornerRadius:8).stroke(active ? Color.accentColor.opacity(0.6) : .clear,lineWidth:1).allowsHitTesting(false))
                                    .id(record.id)
                            }
                        }
                        if records.isEmpty { Text("框选后，转写会实时显示在这里").font(.system(size:12)).foregroundStyle(.secondary).padding(.vertical,12) }
                        Color.clear.frame(height:1).id("transcript-bottom")
                    }.padding(9)
                }.onAppear { proxy.scrollTo("transcript-bottom",anchor:.bottom) }
                    .onChange(of:records.last?.id) { proxy.scrollTo("transcript-bottom",anchor:.bottom) }
                    .onChange(of:records.last?.text) { proxy.scrollTo("transcript-bottom",anchor:.bottom) }
            }
        }.background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:10))
            .overlay(RoundedRectangle(cornerRadius:10).stroke(.gray.opacity(0.3),lineWidth:1).allowsHitTesting(false))
            .clipShape(RoundedRectangle(cornerRadius:10))
            .onAppear { voice.refreshInputDevices() }
            .onReceive(NotificationCenter.default.publisher(for:AVCaptureDevice.wasConnectedNotification).receive(on:DispatchQueue.main)) { _ in voice.refreshInputDevices() }
            .onReceive(NotificationCenter.default.publisher(for:AVCaptureDevice.wasDisconnectedNotification).receive(on:DispatchQueue.main)) { _ in voice.refreshInputDevices() }
    }
}

struct ReviewCompletionView: View {
    @ObservedObject var model: ReviewModel
    var body: some View {
        VStack(spacing:10) {
            HStack(spacing:12) {
                action("Notes",symbol:"note.text") { model.writeReviewToNotes() }
                action(model.copied ? "已复制" : "复制",symbol:model.copied ? "checkmark.circle.fill" : "doc.on.doc") { model.finish() }
                #if !APP_STORE
                action("Codex",symbol:"paperplane") { model.sendToCodex() }
                #endif
            }
            if model.busy { ProgressView().controlSize(.small) }
            else if model.status.contains("失败") {
                Label("操作失败",systemImage:"exclamationmark.circle").font(.system(size:11)).foregroundStyle(.red).help(model.status)
            }
        }.padding(14).frame(width:240,height:96).buttonStyle(.plain).modifier(IslandSurface())
            .onHover { inside in if !inside { model.panels.hideCompletionMenu() } }
    }
    private func action(_ title:String,symbol:String,perform:@escaping ()->Void) -> some View {
        Button(action:perform) {
            VStack(spacing:8) {
                Image(systemName:symbol).font(.system(size:23,weight:.regular)).frame(width:48,height:42)
                    .background(Color.primary.opacity(0.05),in:RoundedRectangle(cornerRadius:10))
                Text(title).font(.system(size:11,weight:.medium))
            }.frame(width:62).contentShape(Rectangle())
        }.disabled(model.busy).help(title).accessibilityLabel(title)
    }
}


@MainActor final class ReviewHistoryWindowDelegate: NSObject, NSWindowDelegate {
    weak var model: ReviewModel?
    init(model:ReviewModel) { self.model = model }
    func windowShouldClose(_ sender:NSWindow) -> Bool {
        Task { await model?.dismissHistory() }
        return false
    }
}

struct ReviewHistoryView: View {
    @State private var summaryPresented = false
    @ObservedObject var model: ReviewModel
    @State private var selectedID: UUID?
    @State private var selectedOpinionID: UUID?
    init(model:ReviewModel) {
        self.model = model
        _selectedID = State(initialValue:model.current?.id ?? model.snapshots.last?.id)
        _selectedOpinionID = State(initialValue:model.selectedID)
    }
    private var selectedIndex: Int { model.snapshots.firstIndex(where:{$0.id == selectedID}) ?? 0 }
    private var selectedShot: ReviewSnapshot? { model.snapshots.first(where:{$0.id == selectedID}) ?? model.snapshots.first }
    private var opinions: [ReviewRegion] { model.regions.filter{$0.snapshotID == selectedShot?.id} }
    private var opinion: ReviewRegion? { opinions.first(where:{$0.id == selectedOpinionID}) ?? opinions.first }
    var body: some View {
        VStack(spacing:0) {
            HStack(alignment:.firstTextBaseline) {
                Text("历史批阅").font(.system(size:21,weight:.semibold))
                Text("\(model.snapshots.count) 张截图 · \(model.regions.count) 条意见").font(.system(size:12)).foregroundStyle(.secondary)
                Spacer()
                Button { move(-1) } label: { Image(systemName:"chevron.left") }.disabled(selectedIndex == 0 || model.busy).help("上一张截图")
                Text("\(selectedIndex+1) / \(model.snapshots.count)").font(.system(size:12)).monospacedDigit().foregroundStyle(.secondary)
                Button { move(1) } label: { Image(systemName:"chevron.right") }.disabled(selectedIndex+1 >= model.snapshots.count || model.busy).help("下一张截图")
            }.padding(.horizontal,22).padding(.top,18).padding(.bottom,12)
            ScrollViewReader { proxy in
                ScrollView(.horizontal,showsIndicators:true) {
                    HStack(spacing:12) {
                        ForEach(Array(model.snapshots.enumerated()),id:\.element.id) { index,shot in
                            Button { selectedID = shot.id } label: {
                                VStack(alignment:.leading,spacing:7) {
                                    Image(nsImage:shot.image).resizable().scaledToFit().frame(width:100,height:54).background(Color.primary.opacity(0.035),in:RoundedRectangle(cornerRadius:6))
                                    HStack { Text("截图 \(index+1)"); Spacer(); Text("\(model.regions.filter{$0.snapshotID == shot.id}.count) 条意见").foregroundStyle(.secondary) }.font(.system(size:11,weight:.medium))
                                }.padding(9).background(selectedShot?.id == shot.id ? Color.accentColor.opacity(0.08) : .clear,in:RoundedRectangle(cornerRadius:9))
                                    .overlay(RoundedRectangle(cornerRadius:9).stroke(selectedShot?.id == shot.id ? Color.accentColor : .gray.opacity(0.2),lineWidth:selectedShot?.id == shot.id ? 2 : 1).allowsHitTesting(false))
                            }.buttonStyle(.plain).disabled(model.busy).id(shot.id).accessibilityLabel("选择截图 \(index+1)")
                        }
                    }.padding(.horizontal,22).padding(.vertical,3)
                }.frame(height:103)
                    .onChange(of:selectedID) {
                        selectedOpinionID = opinions.first?.id
                        if let selectedID { withAnimation { proxy.scrollTo(selectedID,anchor:.center) } }
                    }
                    .onAppear { if let selectedID { proxy.scrollTo(selectedID,anchor:.center) } }
            }
            Divider().padding(.top,6)
            HSplitView {
                if let shot = selectedShot {
                    ReviewHistoryImage(shot:shot,regions:opinions,selectedID:opinion?.id) { selectedOpinionID = $0 }
                        .frame(minWidth:500,idealWidth:850,maxWidth:.infinity,maxHeight:.infinity)
                        .accessibilityLabel("截图 \(selectedIndex+1)，点击框选区域切换意见")
                }
                VStack(alignment:.leading,spacing:12) {
                    if let opinion {
                        HStack {
                            Text("意见 \(opinion.number)").font(.system(size:17,weight:.semibold))
                            Spacer()
                            Text("语音转写").font(.system(size:11)).foregroundStyle(.secondary)
                        }
                        ScrollView {
                            VStack(alignment:.leading,spacing:15) {
                                if let entries = opinion.transcript, !entries.isEmpty {
                                    ForEach(entries) { entry in
                                        HStack(alignment:.top,spacing:14) {
                                            Text(reviewTranscriptTime(entry.recordedAt)).font(.system(size:11,design:.monospaced)).foregroundStyle(.secondary).frame(width:76,alignment:.leading)
                                            Text(entry.text).font(.system(size:14)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
                                        }
                                    }
                                } else {
                                    Label("这条意见没有保存带时间戳的语音片段",systemImage:"clock").font(.system(size:12)).foregroundStyle(.secondary).padding(.vertical,12)
                                }
                            }.padding(.vertical,5)
                        }.frame(maxHeight:.infinity)
                        Divider()
                        HStack { Text("意见内容").font(.system(size:12,weight:.semibold)); Spacer(); Text("可编辑 · 自动保存").font(.system(size:10)).foregroundStyle(.secondary) }
                        TextEditor(text:Binding(get:{model.regions.first(where:{$0.id == opinion.id})?.feedback ?? ""},set:{model.updateOpinion(opinion.id,text:$0)}))
                            .font(.system(size:14)).scrollContentBackground(.hidden).frame(minHeight:100,maxHeight:170).padding(10)
                            .background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:7))
                            .overlay(RoundedRectangle(cornerRadius:7).stroke(.gray.opacity(0.2),lineWidth:1).allowsHitTesting(false))
                            .accessibilityLabel("编辑意见 \(opinion.number)").disabled(model.busy)
                    } else {
                        Spacer(); Text("点击截图中的框选区域查看意见").font(.system(size:14)).foregroundStyle(.secondary).frame(maxWidth:.infinity); Spacer()
                    }
                }.padding(20).frame(minWidth:280,idealWidth:340,maxWidth:420,maxHeight:.infinity,alignment:.topLeading)
            }.frame(minHeight:400,maxHeight:.infinity)
            Divider()
            HStack {
                Text(model.status).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(2)
                Spacer()
                if model.busy { ProgressView().controlSize(.small) }
                #if !APP_STORE
                Button {
                    summaryPresented = true
                    if model.aiSummary.isEmpty { model.summarizeReview() }
                } label: { Label("AI 整理",systemImage:"sparkles") }
                    .help("使用 Codex 整理带框选编号的关键点")
                    .sheet(isPresented:$summaryPresented) { ReviewAISummaryView(model:model) }
                #endif
                Button { model.writeReviewToNotes() } label: { Label("Notes",systemImage:"note.text") }
                    .disabled(model.busy || model.snapshots.isEmpty).help("将全部截图和意见写入 Apple Notes")
                Button { model.finish() } label: { Label(model.copied ? "已复制" : "复制",systemImage:model.copied ? "checkmark" : "doc.on.doc") }
                    .disabled(model.busy || model.snapshots.isEmpty).help("复制全部截图和意见")
                #if !APP_STORE
                Button { model.sendToCodex() } label: { Label("Codex",systemImage:"paperplane") }
                    .disabled(model.busy || model.snapshots.isEmpty).help("将全部截图和意见发送到 Codex 新会话")
                #endif
                Divider().frame(height:18).padding(.horizontal,4)
                Button("保存并关闭") { Task { await model.dismissHistory() } }.keyboardShortcut(.defaultAction).disabled(model.busy)
            }.padding(.horizontal,22).padding(.vertical,12)
        }.frame(minWidth:900,minHeight:660).background(Color(nsColor:.windowBackgroundColor))
    }
    private func move(_ delta:Int) {
        let next = selectedIndex+delta
        if model.snapshots.indices.contains(next) { selectedID = model.snapshots[next].id }
    }
}

func reviewTranscriptTime(_ date:Date) -> String {
    let formatter = DateFormatter(); formatter.locale = Locale(identifier:"en_US_POSIX"); formatter.dateFormat = "HH:mm:ss"
    return formatter.string(from:date)
}

func reviewHistoryImageRect(size:CGSize,bounds:CGRect) -> CGRect {
    guard size.width > 0, size.height > 0 else { return .zero }
    let scale = min(bounds.width/size.width,bounds.height/size.height)
    let fitted = CGSize(width:size.width*scale,height:size.height*scale)
    return CGRect(x:bounds.midX-fitted.width/2,y:bounds.midY-fitted.height/2,width:fitted.width,height:fitted.height)
}
func reviewHistoryRegion(at point:CGPoint,in imageRect:CGRect,regions:[ReviewRegion]) -> UUID? {
    guard imageRect.width > 0, imageRect.height > 0, imageRect.contains(point) else { return nil }
    let normalized = CGPoint(x:(point.x-imageRect.minX)/imageRect.width,y:(point.y-imageRect.minY)/imageRect.height)
    return regions.last(where:{$0.rect.contains(normalized)})?.id
}
struct ReviewHistoryImage: NSViewRepresentable {
    let shot: ReviewSnapshot
    let regions: [ReviewRegion]
    let selectedID: UUID?
    let select: (UUID)->Void
    func makeNSView(context:Context) -> ReviewHistoryImageView { ReviewHistoryImageView() }
    func updateNSView(_ view:ReviewHistoryImageView,context:Context) {
        view.image = shot.image; view.regions = regions; view.selectedID = selectedID; view.select = select
        view.needsDisplay = true; view.window?.invalidateCursorRects(for:view)
    }
}
final class ReviewHistoryImageView: NSView {
    var image: NSImage?
    var regions: [ReviewRegion] = []
    var selectedID: UUID?
    var select: ((UUID)->Void)?
    override var isFlipped:Bool { true }
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool { true }
    private var imageRect: CGRect { reviewHistoryImageRect(size:image?.size ?? .zero,bounds:bounds.insetBy(dx:12,dy:12)) }
    private func rect(_ region:ReviewRegion) -> CGRect {
        let fitted = imageRect
        return CGRect(x:fitted.minX+region.rect.minX*fitted.width,y:fitted.minY+region.rect.minY*fitted.height,width:region.rect.width*fitted.width,height:region.rect.height*fitted.height)
    }
    override func draw(_ dirtyRect:NSRect) {
        NSColor.controlBackgroundColor.setFill(); bounds.fill()
        guard let image else { return }
        image.draw(in:imageRect,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        for region in regions {
            let area = rect(region)
            let color: NSColor = region.id == selectedID ? .systemTeal : .systemBlue
            color.withAlphaComponent(region.id == selectedID ? 0.14 : 0.035).setFill(); area.fill()
            color.setStroke(); let path = NSBezierPath(rect:area); path.lineWidth = region.id == selectedID ? 3 : 1.5; path.stroke()
            let label = CGRect(x:area.minX,y:area.minY,width:30,height:21)
            color.setFill(); label.fill()
            ("#\(region.number)" as NSString).draw(in:label.insetBy(dx:3,dy:2),withAttributes:[.font:NSFont.systemFont(ofSize:11,weight:.semibold),.foregroundColor:NSColor.white])
        }
    }
    override func resetCursorRects() { for region in regions { addCursorRect(rect(region),cursor:.pointingHand) } }
    override func mouseDown(with event:NSEvent) {
        if let id = reviewHistoryRegion(at:convert(event.locationInWindow,from:nil),in:imageRect,regions:regions) { select?(id) }
    }
}

func reviewFilteredTargets(_ targets:[ScreenTarget],query:String) -> [ScreenTarget] {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return targets.filter { item in terms.allSatisfy { item.label.localizedStandardContains($0) } }
}
struct ReviewPanelContent: View {
    @ObservedObject var model: ReviewModel
    var body: some View {
        if model.picking { ReviewTargetPicker(model:model) }
        else { ReviewSidebar(model:model,voice:model.voice) }
    }
}
enum ReviewPickerItem: Hashable {
    case window(UInt32)
    case exit
}
func reviewPickerItems(_ targets:[ScreenTarget],query:String) -> [ReviewPickerItem] {
    let query = query.trimmingCharacters(in:.whitespacesAndNewlines)
    let windows = reviewFilteredTargets(targets,query:query).map { ReviewPickerItem.window($0.id) }
    let exitMatches = query.isEmpty || "退出批阅 exit e".localizedStandardContains(query)
    if query.lowercased() == "e" { return [.exit] + windows }
    return windows + (exitMatches ? [.exit] : [])
}
func reviewPickerHeight(rowCount:Int,availableHeight:CGFloat) -> CGFloat {
    min(availableHeight,520,73 + CGFloat(max(1,rowCount))*58 + CGFloat(max(0,rowCount-1))*2)
}
struct ReviewTargetPicker: View {
    @ObservedObject var model: ReviewModel
    @State private var query = ""
    @State private var selected: ReviewPickerItem?
    private var items: [ReviewPickerItem] { reviewPickerItems(model.targets,query:query) }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:10) {
                ReviewPickerSearch(query:$query,move:move,submit:activateSelection).frame(height:30)
                if model.busy { ProgressView().controlSize(.small) }
                if model.status.contains("无法") || model.status.contains("失败") {
                    Image(systemName:"exclamationmark.circle").foregroundStyle(.orange).help(model.status)
                }
            }.padding(.horizontal,16).frame(height:56)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing:2) {
                        ForEach(items,id:\.self) { item in
                            Button { selected = item; activateSelection() } label: {
                                row(item).padding(.horizontal,10).frame(height:58).frame(maxWidth:.infinity,alignment:.leading)
                                    .contentShape(Rectangle())
                                    .background(selected == item ? Color.accentColor.opacity(0.15) : .clear,in:RoundedRectangle(cornerRadius:8))
                            }.disabled(model.busy).id(item)
                        }
                        if items.isEmpty { Text("无匹配窗口").font(.system(size:12)).foregroundStyle(.secondary).frame(height:58) }
                    }.padding(8)
                }.onChange(of:selected) { if let selected { proxy.scrollTo(selected,anchor:.center) } }
            }
        }.buttonStyle(.plain).background(Color(nsColor:.windowBackgroundColor),in:RoundedRectangle(cornerRadius:14))
            .onAppear { resetSelection() }
            .onChange(of:query) { resetSelection() }
            .onChange(of:model.targets) { resetSelection() }
    }
    @ViewBuilder private func row(_ item:ReviewPickerItem) -> some View {
        if case .window(let id) = item, let target = model.targets.first(where:{$0.id == id}) {
            HStack(spacing:12) {
                if let icon = NSRunningApplication(processIdentifier:target.pid)?.icon {
                    Image(nsImage:icon).resizable().scaledToFit().frame(width:30,height:30)
                } else { Image(systemName:"macwindow").frame(width:30,height:30) }
                VStack(alignment:.leading,spacing:4) {
                    Text(target.app).font(.system(size:13,weight:.medium)).lineLimit(1)
                    if !target.title.isEmpty { Text(target.title).font(.system(size:11)).foregroundStyle(.secondary).lineLimit(1) }
                }
                Spacer()
                if model.target?.id == id { Image(systemName:"checkmark").foregroundStyle(.tint) }
            }.help(target.label)
        } else {
            Label("退出批阅",systemImage:"rectangle.portrait.and.arrow.right").font(.system(size:13)).help("保存并解除目标绑定 · e")
        }
    }
    private func resetSelection() {
        selected = items.first
        model.panels.resizeTargetPicker(rowCount:items.count)
    }
    private func move(_ delta:Int) {
        guard !items.isEmpty else { selected = nil; return }
        let index = selected.flatMap { items.firstIndex(of:$0) } ?? 0
        selected = items[min(max(0,index+delta),items.count-1)]
    }
    private func activateSelection() {
        guard !model.busy, let selected, items.contains(selected) else { return }
        switch selected {
        case .exit: model.close()
        case .window(let id): if let target = model.targets.first(where:{$0.id == id}) { Task { await model.choose(target) } }
        }
    }
}

struct ReviewPickerSearch: NSViewRepresentable {
    @Binding var query: String
    let move: (Int)->Void
    let submit: ()->Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context:Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "搜索应用或窗口"; field.font = .systemFont(ofSize:15)
        field.isBordered = true; field.isBezeled = true; field.bezelStyle = .roundedBezel; field.focusRingType = .none
        field.delegate = context.coordinator
        field.setAccessibilityLabel("搜索应用或窗口")
        DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        return field
    }
    func updateNSView(_ field:NSSearchField,context:Context) {
        context.coordinator.parent = self
        if field.stringValue != query { field.stringValue = query }
    }
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: ReviewPickerSearch
        init(_ parent:ReviewPickerSearch) { self.parent = parent }
        func controlTextDidChange(_ notification:Notification) {
            if let field = notification.object as? NSSearchField { parent.query = field.stringValue }
        }
        func control(_ control:NSControl,textView:NSTextView,doCommandBy commandSelector:Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            if commandSelector == #selector(NSResponder.moveUp(_:)) { parent.move(-1); return true }
            if commandSelector == #selector(NSResponder.moveDown(_:)) { parent.move(1); return true }
            if commandSelector == #selector(NSResponder.insertNewline(_:)) { parent.submit(); return true }
            return false
        }
    }
}


struct ReviewAISummaryView: View {
    @ObservedObject var model: ReviewModel
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment:.leading,spacing:14) {
            HStack {
                Label("AI Summary / CleanUp",systemImage:"sparkles").font(.system(size:17,weight:.semibold))
                Spacer()
                Button("完成") { dismiss() }
            }
            Text("使用 Codex 提取关键点并精简表述，保留框选编号与原始转写。")
                .font(.system(size:11)).foregroundStyle(.secondary)
            if model.summaryOutdated { Text("转写已有更新，可重新整理").font(.system(size:11)).foregroundStyle(.orange) }
            ScrollView {
                Text(model.aiSummary.isEmpty ? (model.summaryBusy ? "正在整理…" : "暂无整理结果") : model.aiSummary)
                    .font(.system(size:14)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            }.frame(maxHeight:.infinity)
            if let error = model.summaryError { Text(error).font(.system(size:11)).foregroundStyle(.orange) }
            HStack {
                if model.summaryBusy { ProgressView().controlSize(.small) }
                Spacer()
                Button("复制整理结果") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.aiSummary,forType:.string) }.disabled(model.aiSummary.isEmpty)
                Button(model.aiSummary.isEmpty ? "整理" : "重新整理") { model.summarizeReview() }.disabled(model.summaryBusy)
            }
        }.padding(20).frame(width:560,height:460)
    }
}

// Activity is derived from actual capture, requests, playback and action receipts.
enum MoActivityTarget { case review, chat, summary, cleanup, reader, meeting }
enum MoActivityKind {
    case idle, reviewing, selecting, connecting, closing, listening, transcribing, thinking, speaking, reading, summarizing, executing, completed, failed
    var priority:Int {
        switch self {
        case .speaking: return 100
        case .executing: return 90
        case .thinking: return 80
        case .reading: return 70
        case .transcribing: return 65
        case .listening: return 60
        case .connecting, .closing: return 55
        case .summarizing: return 30
        case .failed: return 10
        case .completed: return 5
        case .selecting: return 3
        case .reviewing: return 1
        case .idle: return 0
        }
    }
    var symbol:String {
        switch self {
        case .listening: return "mic.fill"
        case .speaking: return "speaker.wave.2.fill"
        case .thinking: return "ellipsis.bubble"
        case .reading: return "viewfinder"
        case .summarizing: return "sparkles"
        case .executing: return "arrow.triangle.2.circlepath"
        case .completed: return "checkmark"
        case .failed: return "exclamationmark.triangle.fill"
        case .transcribing: return "text.bubble"
        case .connecting, .closing: return "network"
        case .selecting: return "macwindow"
        case .reviewing: return "square.and.pencil"
        case .idle: return "circle"
        }
    }
    var color:Color {
        switch self {
        case .failed: return .orange
        case .listening: return .red
        case .speaking: return .cyan
        case .summarizing, .thinking: return .purple
        case .completed: return .green
        default: return .mint
        }
    }
    var animated:Bool { priority >= 30 && self != .listening && self != .speaking }
}
struct MoActivity: Identifiable {
    let id:String
    let kind:MoActivityKind
    let title:String
    var target:MoActivityTarget = .review
    var level:CGFloat = 0
    var detail = ""
    var expiresAt:Date? = nil
}
struct MoActivityState {
    let primary:MoActivity
    let secondary:[MoActivity]
    var context = ""
    static func resolve(_ activities:[MoActivity],now:Date = Date()) -> MoActivityState {
        let sorted = activities.filter { $0.expiresAt.map { $0 > now } ?? true }.sorted {
            $0.kind.priority == $1.kind.priority ? $0.id < $1.id : $0.kind.priority > $1.kind.priority
        }
        return MoActivityState(primary:sorted.first ?? MoActivity(id:"idle",kind:.idle,title:"就绪"),secondary:Array(sorted.dropFirst()).filter { $0.kind != .reviewing })
    }
    var description:String { ([context] + ([primary]+secondary).map { $0.title + ($0.detail.isEmpty ? "" : "："+$0.detail) }).filter{!$0.isEmpty}.joined(separator:"\n") }
}
extension ReviewModel {
    var activityState:MoActivityState {
        var items = externalActivities?() ?? []
        if live.outputPlaying { items.append(MoActivity(id:"speaking",kind:.speaking,title:"正在回答",target:.chat,level:live.outputLevel)) }
        if live.active {
            if live.closing { items.append(MoActivity(id:"closing",kind:.closing,title:"结束对话",target:.chat)) }
            else if live.ready && live.capturing { items.append(MoActivity(id:"listening",kind:.listening,title:"正在聆听",target:.chat,level:live.inputLevel)) }
            else if live.ready { items.append(MoActivity(id:"live-start",kind:.connecting,title:"启动录音",target:.chat)) }
            else { items.append(MoActivity(id:"connecting",kind:.connecting,title:"连接对话",target:.chat)) }
        }
        if voice.voicePreparing { items.append(MoActivity(id:"voice-start",kind:.connecting,title:"启动录音",target:.chat)) }
        if voice.dictating { items.append(MoActivity(id:"dictation",kind:.listening,title:active && !speakingEnabled ? "静默记录" : "正在录音",target:.chat,level:voice.inputLevel)) }
        if voice.voiceFinishing { items.append(MoActivity(id:"transcribing",kind:.transcribing,title:"正在转写",target:.chat)) }
        if active {
            if textChatBusy { items.append(MoActivity(id:"thinking",kind:.thinking,title:"正在思考",target:.chat)) }
            if let error = textChatError { items.append(MoActivity(id:"chat-error",kind:.failed,title:"回复失败",target:.chat,detail:error)) }
            if liveSummary.enabled, liveSummary.updating { items.append(MoActivity(id:"summary",kind:.summarizing,title:"正在整理",target:.summary)) }
            if liveSummary.enabled, let error = liveSummary.error { items.append(MoActivity(id:"summary-error",kind:.failed,title:"摘要失败",target:.summary,detail:error)) }
            if summaryBusy { items.append(MoActivity(id:"cleanup",kind:.summarizing,title:"整理批阅",target:.cleanup)) }
            if let error = summaryError { items.append(MoActivity(id:"cleanup-error",kind:.failed,title:"整理失败",target:.cleanup,detail:error)) }
            if let error = voice.lastError { items.append(MoActivity(id:"voice-error",kind:.failed,title:"录音异常",target:.chat,detail:error)) }
            if let error = live.lastError { items.append(MoActivity(id:"live-error",kind:.failed,title:"对话异常",target:.chat,detail:error)) }
            items.append(MoActivity(id:"review",kind:picking ? .selecting : .reviewing,title:picking ? "选择窗口" : historyPresented ? "历史批阅" : paused ? (inputMode == .text ? "文字批阅" : "正在批阅") : "批阅就绪"))
        }
        if let workActivity { items.append(workActivity) }
        var state = MoActivityState.resolve(items)
        let external = state.primary.target == .reader || state.primary.target == .meeting
        let region = external ? nil : regions.first(where:{$0.id == selectedID}).map { "#\($0.number)" }
        let label = external ? externalActivityContext?(state.primary.target) : target?.label
        state.context = [label,region,external ? nil : speakingEnabled ? "发言模式" : active ? "静默模式" : nil].compactMap{$0}.joined(separator:" · ")
        return state
    }
    @discardableResult func beginActivity(_ title:String) -> String {
        let id = UUID().uuidString
        workActivity = MoActivity(id:id,kind:.executing,title:title)
        return id
    }
    func endActivity(_ id:String,result:String,failed:Bool = false) {
        guard workActivity?.id == id else { return }
        workActivity = MoActivity(id:id,kind:failed ? .failed : .completed,title:result,detail:failed ? status : "",expiresAt:failed ? nil : Date().addingTimeInterval(3))
    }
    func showActivity(_ destination:MoActivityTarget) {
        guard active else { return }
        if let target, target.pid > 0 { NSRunningApplication(processIdentifier:target.pid)?.activate() }
        switch destination {
        case .summary: if liveSummary.enabled { conversationTab = .summary }
        case .cleanup: cleanupPresented = true; conversationTab = .chat
        case .chat: conversationTab = .chat
        default: break
        }
        if [.chat,.summary,.cleanup].contains(destination) { panels.showConversation() }
        else if historyPresented { panels.showHistory() }
        else if active { panels.showSidebar() }
    }
}

struct MoActivityAvatar:View {
    let state:MoActivityState
    var size:CGFloat = 30
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        TimelineView(.animation(minimumInterval:1/15,paused:reduceMotion)) { context in
            let phase = reduceMotion ? 0.5 : (sin(context.date.timeIntervalSinceReferenceDate*2.5)+1)/2
            ZStack {
                Circle().stroke(state.primary.kind.color.opacity(0.3+phase*0.5),lineWidth:2).scaleEffect(1+phase*0.08)
                Image(nsImage:MascotAssets.images["jay"]!).resizable().interpolation(.high).scaledToFill()
                    .frame(width:size-4,height:size-4).scaleEffect(1.3,anchor:UnitPoint(x:0.46,y:0.62)).clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.65),lineWidth:1))
                Image(systemName:state.primary.kind.symbol).font(.system(size:max(7,size*0.22),weight:.semibold)).foregroundStyle(.white)
                    .padding(3).background(state.primary.kind.color,in:Circle()).offset(x:size*0.35,y:size*0.35)
                if state.secondary.contains(where:{$0.kind == .listening}) {
                    Circle().fill(.red).frame(width:max(5,size*0.16),height:max(5,size*0.16)).overlay(Circle().stroke(.white,lineWidth:1)).offset(x:size*0.33,y:-size*0.33)
                }
                if let extra = state.secondary.first(where:{$0.kind == .failed}) ?? state.secondary.first(where:{$0.kind == .summarizing}) {
                    Image(systemName:extra.kind.symbol).font(.system(size:max(6,size*0.18),weight:.semibold)).foregroundStyle(.white)
                        .padding(3).background(extra.kind.color,in:Circle()).offset(x:-size*0.35,y:-size*0.35)
                }
            }.frame(width:size,height:size)
        }.accessibilityLabel("默默，"+state.description)
    }
}
struct MoActivityStatus:View {
    let state:MoActivityState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        HStack(spacing:4) {
            if [.listening,.speaking].contains(state.primary.kind) {
                HStack(spacing:2) { ForEach(0..<3) { index in Capsule().fill(state.primary.kind.color).frame(width:2,height:4+max(0,min(1,state.primary.level))*CGFloat([8,15,10][index])) } }.frame(width:10)
            } else if state.primary.kind.animated {
                Image(systemName:state.primary.kind.symbol).foregroundStyle(state.primary.kind.color)
                    .symbolEffect(.pulse,options:.repeating,isActive:!reduceMotion)
            } else { Image(systemName:state.primary.kind.symbol).foregroundStyle(state.primary.kind.color) }
            Text(state.primary.title).foregroundStyle(.white).lineLimit(1)
            ForEach(Array((state.secondary.filter{$0.kind == .failed} + state.secondary.filter{$0.kind != .failed}).prefix(2))) { item in
                Image(systemName:item.kind.symbol).foregroundStyle(item.kind.color).font(.system(size:8)).help(item.title)
            }
        }.font(.system(size:10,weight:.medium)).help(state.description).accessibilityElement(children:.ignore).accessibilityLabel(state.description)
    }
}
