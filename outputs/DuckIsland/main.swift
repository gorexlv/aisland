import Cocoa
import SwiftUI
import Speech
import AVFoundation
import Combine

func sentenceCount(_ text: String) -> Int {
    let parts = text.components(separatedBy: CharacterSet(charactersIn: "。！？.!?\n"))
    return parts.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
}

@MainActor final class Recorder: ObservableObject {
    let screenReader = ScreenReader()
    let review = ReviewModel()
    private var screenChanges: AnyCancellable?
    @Published var recording = false
    @Published var audioStatus = "系统声音：等待接入   ·   麦克风：等待接入"
    @Published var busy = false
    @Published var transcript = ""
    @Published var message = "选择会议，记录系统声音和麦克风"
    @Published var level: CGFloat = 0
    @Published var expanded = false
    @Published var showMenu = false
    @Published var copied = false
    @Published var noteSaved = false
    @Published var savedNoteName = ""
    @Published var savedNoteFolder = ""
    @Published var analysisText = ""
    @Published var analysisError = ""
    @Published var toast = ""
    @Published var processing = false
    private var toastToken = UUID()
    private var sessionID = UUID()
    private var jobs: Set<UUID> = []
    var hasBackgroundJobs: Bool { !jobs.isEmpty }
    private var noteID: String?
    @Published var notchWidth: CGFloat = 220
    @Published var notchHeight: CGFloat = 38
    private var capture: MeetingCapture?
    private let recognition = MeetingRecognition()
    private var title = ""
    private var backupURL: URL?
    private var lastBackup = Date.distantPast
    private var warning = ""
    var count: Int { sentenceCount(transcript) }

    init() {
        screenReader.onNotice = { [weak self] text in self?.notify(text) }
        review.onNotice = { [weak self] text in self?.notify(text) }
        screenChanges = screenReader.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        recognition.onAudioStatus = { [weak self] status in self?.audioStatus = status }
        recognition.onText = { [weak self] text in
            guard let self else { return }
            self.transcript = text
            if Date().timeIntervalSince(self.lastBackup) > 1 { self.persist(); self.lastBackup = Date() }
        }
        recognition.onLevel = { [weak self] volume in
            guard let self else { return }
            self.level = max(volume, self.level * 0.92)
        }
        recognition.onWarning = { [weak self] text in
            guard let self, self.recording, !self.busy else { return }
            self.warning = text
            Task { @MainActor in await self.stopMeeting() }
        }
    }
    func toggle() {
        guard !busy else { return }
        screenReader.hide()
        if recording { Task { @MainActor in await stopMeeting() }; return }
        showMenu.toggle()
        expanded = showMenu || !transcript.isEmpty
    }
    func startReview() {
        guard !recording, !busy else { notify("请先结束会议，再开启批阅"); return }
        screenReader.cancel(); screenReader.hide(); expanded = false; showMenu = false
        review.start()
    }
    func readScreen() {
        guard !review.active else { notify("请先关闭批阅"); return }
        guard !recording, !busy else { notify("请先结束会议，再开启读屏"); return }
        showMenu = false; expanded = false; screenReader.open()
    }
    func meeting() {
        guard !review.active else { notify("请先关闭批阅"); return }
        guard !busy else { return }
        screenReader.cancel(); screenReader.hide()
        if recording { Task { @MainActor in await stopMeeting() }; return }
        #if APP_STORE
        if !UserDefaults.standard.bool(forKey:"meetingDisclosureAccepted") {
            let alert = NSAlert()
            alert.messageText = "开始会议转写"
            alert.informativeText = "将采集 Mac 的系统声音（包括其他应用）与麦克风，不保存会议画面或原始录音文件。语音可能由 Apple 在线识别。结束后保存本地文字，并申请写入 Apple 备忘录。请先告知参会者并取得所需同意。"
            alert.addButton(withTitle:"继续")
            alert.addButton(withTitle:"取消")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            UserDefaults.standard.set(true,forKey:"meetingDisclosureAccepted")
        }
        #endif
        showMenu = false; expanded = true; busy = true
        Task { @MainActor in
            defer { busy = false }
            do {
                message = "正在检查麦克风权限…"
                let microphone = await AVCaptureDevice.requestAccess(for: .audio)
                guard microphone else {
                    permissionAlert("需要麦克风权限", detail: "用于录制你在会议中说的话。", setting: "Privacy_Microphone")
                    return
                }
                message = "正在检查语音识别权限…"
                let speech: SFSpeechRecognizerAuthorizationStatus = await withCheckedContinuation { continuation in
                    SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0) }
                }
                guard speech == .authorized else {
                    permissionAlert("需要语音识别权限", detail: "用于把会议音频转换成文字。", setting: "Privacy_SpeechRecognition")
                    return
                }
                // ScreenCaptureKit itself requests and validates capture permission.
                // Do not gate it on the legacy CoreGraphics screen-capture preflight.
                message = "正在准备系统音频采集…"
                try recognition.start()
                let formatter = DateFormatter()
                formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
                sessionID = UUID(); processing = false
                title = "会议记录 " + formatter.string(from: Date())
                let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("DuckIsland/Meetings", isDirectory: true)
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                backupURL = folder.appendingPathComponent(title.replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(6) + ".txt")
                transcript = ""; noteSaved = false; warning = ""
                audioStatus = "系统声音：等待接入   ·   麦克风：等待接入"
                savedNoteName = ""; savedNoteFolder = ""; noteID = nil; analysisText = ""; analysisError = ""
                let newCapture = MeetingCapture()
                newCapture.onSample = { [recognition] sample, source in
                    recognition.append(sample, source: source)
                }
                newCapture.onFailure = { [weak self] error in
                    DispatchQueue.main.async {
                        guard let self, self.recording, !self.busy else { return }
                        self.warning = "音频采集中断：\(error.localizedDescription)"
                        Task { @MainActor in await self.stopMeeting() }
                    }
                }
                capture = newCapture
                try await newCapture.start()
                recording = true
                message = "会议中 · 系统声音 + 麦克风 · 再点小鸭结束"
                persist()
            } catch {
                if let capture { try? await capture.stop() }
                capture = nil; recognition.cancel(); recording = false
                message = "启动失败：\(error.localizedDescription)"
            }
        }
    }
    private func permissionAlert(_ title: String, detail: String, setting: String) {
        message = title + "，授权后请重试"
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = detail
        alert.addButton(withTitle: "打开系统设置")
        alert.addButton(withTitle: "稍后")
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?" + setting) {
            NSWorkspace.shared.open(url)
        }
    }
    @MainActor func stopMeeting() async {
        guard recording, !busy else { return }
        busy = true; showMenu = false; expanded = false
        message = "正在结束录音并整理文字…"
        if let capture {
            do { try await capture.stop() }
            catch { warning = "停止音频采集时出错：\(error.localizedDescription)" }
        }
        capture = nil; recording = false; level = 0
        recognition.finish()
        // Bounded admission and per-chunk deadlines bound the drain duration.
        while recognition.pending {
            message = "正在完成转写 · 剩余 \(recognition.pendingCount) 个音频片段…"
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        transcript = recognition.finalText()
        if recognition.isIncomplete {
            warning = ([warning, "转写不完整：部分音频未能完成识别，原音未保存，无法恢复。"].filter { !$0.isEmpty }).joined(separator: "；")
        }
        persist()
        let emptyReason = recognition.emptyResultReason
        let diagnostics = recognition.diagnosticSummary
        if let backupURL {
            try? diagnostics.write(to: backupURL.deletingPathExtension().appendingPathExtension("diagnostics.txt"), atomically: true, encoding: .utf8)
        }
        recognition.cancel()
        if transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            message = warning.isEmpty ? emptyReason : warning
        } else {
            #if APP_STORE
            enqueueSave(analyze: false)
            #else
            enqueueSave(analyze: true)
            #endif
        }
        busy = false
    }
    @MainActor private func enqueueSave(analyze: Bool) {
        guard !processing, !transcript.isEmpty else { return }
        let jobID = sessionID
        let input = transcript, jobTitle = title, url = backupURL, existingID = noteID
        let jobWarning = warning, previousAnalysis = analysisText, previousError = analysisError
        processing = true; jobs.insert(jobID)
        expanded = false; showMenu = false
        message = "会议正在后台整理和保存"
        Task { @MainActor in
            let result = await Task.detached(priority: .utility) { () -> BackgroundSaveResult in
                finishMeetingInBackground(title: jobTitle, transcript: input, warning: jobWarning,
                    backupURL: url, existingID: existingID, analyze: analyze,
                    previousAnalysis: previousAnalysis, previousError: previousError)
            }.value
            jobs.remove(jobID)
            if sessionID == jobID {
                processing = false
                analysisText = result.analysis
                analysisError = result.analysisError
                if let receipt = result.receipt {
                    noteID = receipt.id; savedNoteName = receipt.name; savedNoteFolder = receipt.folder
                    noteSaved = true
                }
                message = result.error ?? (jobWarning.isEmpty ? (result.analysisError.isEmpty ? "会议已保存" : "原文已保存；总结失败，可重试") : "会议已保存，但转写不完整；请查看记录中的警告")
            }
            if let receipt = result.receipt {
                notify((!jobWarning.isEmpty ? "已保存（转写不完整）：" : (result.analysisError.isEmpty ? "已保存：" : "原文已保存（总结失败）：")) + receipt.name)
            } else {
                notify("保存失败，文字已保留在本地备份")
            }
        }
    }
    @MainActor func notify(_ text: String) {
        let token = UUID(); toastToken = token; toast = text
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if toastToken == token { toast = "" }
        }
    }
    #if !APP_STORE
    func retryAnalysis() {
        guard !busy, !recording else { return }
        Task { @MainActor in enqueueSave(analyze: true) }
    }
    #endif
    var noteBody: String {
        meetingBody(transcript: transcript, analysis: analysisText, error: analysisError, warning: warning)
    }
    func openSavedNote() { if let noteID { openNote(id: noteID) } }
    private func persist() {
        guard let backupURL else { return }
        do { try (title + "\n\n" + (analysisText.isEmpty && analysisError.isEmpty ? transcript : noteBody)).write(to: backupURL, atomically: true, encoding: .utf8) }
        catch { message = "本地文字备份失败：\(error.localizedDescription)" }
    }
    func saveToNotes() {
        guard !noteSaved, !busy, !recording else { return }
        Task { @MainActor in enqueueSave(analyze: false) }
    }
    func revealBackup() {
        if let backupURL { NSWorkspace.shared.activateFileViewerSelecting([backupURL]) }
    }
    func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(transcript, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.copied = false }
    }
}

private struct DuckMascot: View {
    let recording: Bool
    let level: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate
            let breath = sin(time * 1.8)
            Image(nsImage: MascotAssets.images["duck"]!)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width:36,height:36)
                .rotationEffect(.degrees(reduceMotion ? 0 : breath * 3 + (hovering ? -7 : 0)))
                .offset(y:reduceMotion ? 0 : breath * 0.9)
                .scaleEffect(reduceMotion ? 1 : (hovering ? 1.08 : 1) + breath * 0.015 + (recording ? min(max(level,0),1) * 0.08 : 0))
                .frame(width:40,height:38)
        }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .spring(response:0.35,dampingFraction:0.6),value:hovering)
        .accessibilityHidden(true)
    }
}

private struct DuckButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration) -> some View {
        configuration.label
            .contentShape(Rectangle())
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.86 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(reduceMotion ? nil : .spring(response:0.3,dampingFraction:0.45),value:configuration.isPressed)
    }
}

struct IslandView: View {
    @ObservedObject var model: Recorder
    let yellow = Color(red: 1, green: 0.82, blue: 0.23)
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Button(action: model.toggle) {
                    DuckMascot(recording: model.recording, level: model.level)
                        .frame(width: 84, height: model.notchHeight)
                }.buttonStyle(DuckButtonStyle()).disabled(model.busy)
                    .help(model.recording ? "结束会议并写入备忘录" : "打开功能菜单")
                    .accessibilityLabel(model.recording ? "结束会议并写入备忘录" : "打开功能菜单")
                Color.black.frame(width: model.notchWidth + 12, height: model.notchHeight)
                Button { withAnimation(.spring(response: 0.4)) { model.screenReader.hide(); model.showMenu = false; model.expanded.toggle() } } label: {
                    HStack(spacing: 5) {
                        HStack(alignment: .center, spacing: 3) {
                            ForEach(0..<5) { index in
                                Capsule().fill(model.recording ? yellow : Color.gray.opacity(0.65))
                                    .frame(width: 3, height: model.recording ? 4 + model.level * CGFloat([12, 20, 10, 16, 8][index]) : CGFloat([7, 13, 19, 13, 7][index]))
                            }
                        }.frame(height: 26).animation(.easeOut(duration: 0.12), value: model.level)
                        if model.count > 0 || model.recording {
                            Text("\(model.count)").font(.system(size: 16, weight: .medium, design: .rounded)).monospacedDigit()
                                .contentTransition(.numericText()).animation(.spring(), value: model.count)
                            Text("句").font(.system(size: 10)).foregroundStyle(.gray)
                        }
                    }.foregroundStyle(yellow).frame(width: 84)
                }.buttonStyle(.plain).help("展开或收起文字 · 按标点估算句数")
            }.frame(height: model.notchHeight + 2)
            if !model.toast.isEmpty {
                Text(model.toast).font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white).lineLimit(1).truncationMode(.middle)
                    .padding(.horizontal, 14).frame(height: 32)
                    .background(.black, in: Capsule())
                    .padding(.top, 8).padding(.bottom, 4)
                    .accessibilityLabel(model.toast)
            }
            if model.showMenu {
                HStack(alignment: .top, spacing: 0) {
                    Button(action: model.meeting) {
                        HangingMascot(name: "monkey", phase: 0)
                    }.buttonStyle(MascotButtonStyle()).disabled(model.busy)
                        .help("会议 · 录制系统声音和麦克风").accessibilityLabel("猴子 · 会议")
                    Button(action: model.readScreen) {
                        HangingMascot(name: "koala", phase: 1.8)
                    }.buttonStyle(MascotButtonStyle()).disabled(model.busy || model.recording)
                        .help("读屏 · 框选识别并保存文字").accessibilityLabel("树袋熊 · 读屏")
                    Button(action: model.startReview) {
                        HangingMascot(name: "parrot", phase: 3.6)
                    }.buttonStyle(MascotButtonStyle()).disabled(model.busy || model.recording)
                        .help("批阅 · 截图框选和语音评审").accessibilityLabel("鹦鹉 · 批阅")
                    Spacer(minLength: 0)
                }.padding(.leading, 6).padding(.top, -4).padding(.bottom, 12)
                    .transition(.opacity)
            } else if model.screenReader.visible {
                ScreenReaderView(reader: model.screenReader)
            } else if model.expanded {
                Rectangle().fill(.white.opacity(0.09)).frame(height: 1).padding(.horizontal, 22)
                Text(model.audioStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(model.recording ? yellow : .gray)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 22).padding(.top, 12)
                ScrollViewReader { proxy in
                    ScrollView {
                        Text(model.transcript.isEmpty ? (model.recording ? "正在听…" : "点击小鸭，选择「会议」。\n结束后自动写入 Apple 备忘录。") : model.transcript)
                            .font(.system(size: 16)).lineSpacing(7)
                            .foregroundStyle(model.transcript.isEmpty ? Color.gray : Color.white.opacity(0.92))
                            .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Color.clear.frame(height: 1).id("bottom")
                    }.frame(height: 138).padding(22)
                        .onChange(of: model.transcript) { proxy.scrollTo("bottom", anchor: .bottom) }
                }
                if !model.recording && !model.busy && !model.processing && !model.transcript.isEmpty {
                    if !model.savedNoteName.isEmpty {
                        Button(action: model.openSavedNote) {
                            HStack(spacing: 8) {
                                Image(systemName: "note.text")
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(model.savedNoteName).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                    Text(model.savedNoteFolder + " · 点击打开").font(.system(size: 10)).foregroundStyle(.gray)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").font(.system(size: 10))
                            }.padding(10).background(yellow.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                        }.buttonStyle(.plain).foregroundStyle(yellow).padding(.horizontal, 22).padding(.bottom, 10)
                    }
                    HStack {
                        Button(model.noteSaved ? "已写入备忘录" : "写入备忘录") { model.saveToNotes() }.disabled(model.noteSaved)
                        #if !APP_STORE
                        if !model.analysisError.isEmpty {
                            Button("重试总结") { model.retryAnalysis() }.help(model.analysisError)
                        }
                        #endif
                        Spacer()
                        Button("本地文字备份") { model.revealBackup() }
                    }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(yellow).padding(.horizontal, 22).padding(.bottom, 12)
                }
                HStack(spacing: 7) {
                    Circle().fill(model.recording ? yellow : .gray).frame(width: 5, height: 5)
                    Text(model.message).font(.system(size: 10)).foregroundStyle(.gray).lineLimit(3)
                    Spacer()
                    Button(model.copied ? "已复制" : "复制") { model.copy() }.disabled(model.transcript.isEmpty)
                    Button { withAnimation { model.expanded = false; model.showMenu = false } } label: { Image(systemName: "chevron.up") }
                }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(yellow).padding(.horizontal, 22).padding(.bottom, 18)
            }
        }
        .frame(width: model.screenReader.visible && !model.showMenu ? max(420, model.notchWidth + 180) : (model.expanded && !model.showMenu ? max(460, model.notchWidth + 180) : model.notchWidth + 180))
        .background(alignment: .top) {
            UnevenRoundedRectangle(topLeadingRadius: 0,
                bottomLeadingRadius: model.expanded && !model.showMenu ? 28 : 18,
                bottomTrailingRadius: model.expanded && !model.showMenu ? 28 : 18,
                topTrailingRadius: 0)
                .fill(.black)
                .frame(height: model.showMenu || (!model.expanded && !model.screenReader.visible) ? model.notchHeight + 2 : nil)
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
        .animation(.spring(response: 0.42, dampingFraction: 0.85), value: model.expanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: model.showMenu)
        .contextMenu {
            Button(model.recording ? "结束会议并写入备忘录" : "打开功能菜单", action: model.toggle)
            Button("复制文字", action: model.copy).disabled(model.transcript.isEmpty)
            Divider()
            Button("退出小鸭") { NSApp.terminate(nil) }
        }
    }
}

struct MascotButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.96 : 1, anchor: .top)
    }
}
enum MascotAssets {
    static let images: [String: NSImage] = Dictionary(uniqueKeysWithValues: ["monkey", "koala", "parrot", "duck"].map { name in
        let url = Bundle.main.resourceURL!.appendingPathComponent(name + ".png")
        return (name, NSImage(contentsOf: url)!)
    })
}
struct HangingMascot: View {
    let name: String
    let phase: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion)) { context in
            let time = context.date.timeIntervalSinceReferenceDate
            let angle = reduceMotion ? 0 : sin(time * 1.65 + phase) * (hovering ? 5 : 2.5)
            Image(nsImage: MascotAssets.images[name]!)
                .resizable().interpolation(.high).scaledToFit()
                .frame(width: 88, height: 88, alignment: .top)
                .rotationEffect(.degrees(angle), anchor: UnitPoint(x: 0.48, y: 0))
                .shadow(color: .black.opacity(0.18), radius: 2, y: 3)
        }
        .frame(width: 88, height: 96, alignment: .top)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityHidden(true)
    }
}
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = Recorder()
    var panel: IslandPanel!
    var statusItem: NSStatusItem!
    var expansion: AnyCancellable?
    var screenLayout: AnyCancellable?
    func applicationDidFinishLaunching(_ notification: Notification) {
        panel = IslandPanel(contentRect: NSRect(x: 0, y: 0, width: 490, height: 330), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false; panel.backgroundColor = .clear
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.mainMenu.rawValue + 3); panel.hasShadow = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none
        panel.contentView = NSHostingView(rootView: IslandView(model: model))
        position()
        expansion = model.$expanded.combineLatest(model.$showMenu, model.$busy, model.$toast).sink { [weak self] expanded, menu, _, toast in
            DispatchQueue.main.async { self?.position(expanded: expanded, menu: menu, toast: toast) }
        }
        screenLayout = model.screenReader.objectWillChange.sink { [weak self] in
            DispatchQueue.main.async { self?.position() }
        }
        NotificationCenter.default.addObserver(self, selector: #selector(screenChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(spaceChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        panel.orderFrontRegardless()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🐤"
        let menu = NSMenu()
        menu.addItem(withTitle: "显示小鸭", action: #selector(show), keyEquivalent: "")
        menu.addItem(withTitle: "回到屏幕顶部", action: #selector(reset), keyEquivalent: "")
        #if APP_STORE
        menu.addItem(withTitle:"隐私与使用说明",action:#selector(showPrivacy),keyEquivalent:"")
        menu.addItem(withTitle:"查看本地记录",action:#selector(showRecords),keyEquivalent:"")
        #endif
        menu.addItem(NSMenuItem.separator())
        menu.addItem(withTitle: "退出", action: #selector(quit), keyEquivalent: "q")
        for item in menu.items { item.target = self }
        statusItem.menu = menu
    }
    func position(expanded: Bool? = nil, menu: Bool? = nil, toast: String? = nil) {
        guard let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }) ?? NSScreen.main else { return }
        var center = screen.frame.midX
        var notch: CGFloat = 120
        if let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            notch = right.minX - left.maxX
            center = (right.minX + left.maxX) / 2
        }
        model.notchWidth = notch
        model.notchHeight = max(32, screen.safeAreaInsets.top)
        let isExpanded = expanded ?? model.expanded
        let screenReader = model.screenReader.visible && !(menu ?? model.showMenu)
        let width = screenReader ? max(420, notch + 180) : (isExpanded && !(menu ?? model.showMenu) ? max(460, notch + 180) : notch + 180)
        let height = model.notchHeight + ((menu ?? model.showMenu) ? 106 : (screenReader ? 306 : (isExpanded ? 352 : 2))) + ((toast ?? model.toast).isEmpty ? 0 : 44)
        panel.setFrame(NSRect(x: center - width / 2, y: screen.frame.maxY - height, width: width, height: height), display: true)
    }
    @objc func spaceChanged() { panel.orderFrontRegardless() }
    @objc func screenChanged() { position() }
    @objc func show() { panel.orderFrontRegardless() }
    @objc func reset() { position(); show() }
    #if APP_STORE
    @objc func showPrivacy() {
        if let url = Bundle.main.url(forResource:"Privacy",withExtension:"html") { NSWorkspace.shared.open(url) }
    }
    @objc func showRecords() {
        do {
            let root = try FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true).appendingPathComponent("DuckIsland")
            try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
            NSWorkspace.shared.open(root)
        } catch { model.notify("无法打开记录目录：" + error.localizedDescription) }
    }
    #endif
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        model.review.close()
        if model.review.active { return .terminateCancel }
        model.screenReader.cancel(); model.screenReader.hide()
        if model.recording && !model.busy {
            Task { @MainActor in
                await model.stopMeeting()
                while model.hasBackgroundJobs { try? await Task.sleep(nanoseconds: 200_000_000) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        if model.hasBackgroundJobs {
            Task { @MainActor in
                while model.hasBackgroundJobs { try? await Task.sleep(nanoseconds: 200_000_000) }
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
        return model.busy ? .terminateCancel : .terminateNow
    }
}
#if APP_STORE && !DEBUG
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#else
if CommandLine.arguments.contains("--notes-worker") {
    runNotesWorker()
} else if CommandLine.arguments.contains("--self-test") {
    assert(sentenceCount("") == 0)
    assert(sentenceCount("你好。今天好吗？很好！") == 3)
    assert(sentenceCount("正在说的一句话") == 1)
    assert(sentenceCount("One. Two!\nThree?") == 3)
    print("Sentence count checks passed")
    runMeetingTests()
} else if let index = CommandLine.arguments.firstIndex(of: "--test-capture"), CommandLine.arguments.count > index + 1 {
    probeCapture(path: CommandLine.arguments[index + 1])
} else if let index = CommandLine.arguments.firstIndex(of: "--test-speech"), CommandLine.arguments.count > index + 1 {
    probeSpeech(path: CommandLine.arguments[index + 1])
} else if CommandLine.arguments.contains("--test-analysis") {
    #if !APP_STORE
    do {
        let result = try analyzeMeeting("[00:02] 会议声音：今天决定修复登录失败问题。小王负责，本周五前完成。验收要求连续登录十次都成功。\n[00:12] 我的麦克风：我来整理复现步骤，明天发给小王。")
        guard !result.tickets.isEmpty else { throw NotesFailure(detail: "测试会议的明确任务未被提取") }
        print(result.rendered)
    } catch { fputs("分析测试失败：\(error.localizedDescription)\n", stderr); exit(1) }
    #endif
} else {
    let app = NSApplication.shared
    let delegate = MainActor.assumeIsolated { AppDelegate() }
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}

#endif
