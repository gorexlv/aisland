import Cocoa
import SwiftUI
import Vision

struct ScreenReadResult {
    let text: String
    let image: Data
}
func recognizeScreenRegion(png: Data, region: CGRect) throws -> ScreenReadResult {
    guard region.width > 0, region.height > 0, region.minX >= 0, region.minY >= 0,
          region.maxX <= 1.000001, region.maxY <= 1.000001,
          let rep = NSBitmapImageRep(data:png), let original = rep.cgImage else { throw NotesFailure(detail:"框选范围无效，请重新框选") }
    let rect = CGRect(x:region.minX*CGFloat(original.width),y:region.minY*CGFloat(original.height),width:region.width*CGFloat(original.width),height:region.height*CGFloat(original.height)).integral
    guard let cropped = original.cropping(to:rect), let data = NSBitmapImageRep(cgImage:cropped).representation(using:.png,properties:[:]) else { throw NotesFailure(detail:"无法读取框选图片") }
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["zh-Hans","en-US"]
    request.usesLanguageCorrection = true
    try VNImageRequestHandler(cgImage:cropped,options:[:]).perform([request])
    let text = (request.results ?? []).compactMap{$0.topCandidates(1).first?.string}.joined(separator:"\n").trimmingCharacters(in:.whitespacesAndNewlines)
    return ScreenReadResult(text:text,image:data)
}
func saveScreenRead(_ result:ScreenReadResult, source:ScreenTarget, region:CGRect, root:URL? = nil) throws -> URL {
    guard !result.text.isEmpty else { throw NotesFailure(detail:"框选区域没有识别到文字，请重新框选") }
    let directory = try root ?? ( FileManager.default.url(for:.applicationSupportDirectory,in:.userDomainMask,appropriateFor:nil,create:true)).appendingPathComponent("DuckIsland/ScreenReads")
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    let date = DateFormatter(); date.dateFormat = "yyyy-MM-dd_HH-mm-ss"
    let folder = directory.appendingPathComponent(date.string(from:Date())+"-"+UUID().uuidString.prefix(8))
    try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
    do {
        try result.image.write(to:folder.appendingPathComponent("region.png"),options:.atomic)
        let metadata = ["应用":source.app,"窗口":source.title,"框选范围":"\(region)"]
        try JSONEncoder().encode(metadata).write(to:folder.appendingPathComponent("source.json"),options:.atomic)
        let textFile = folder.appendingPathComponent("文字.txt")
        try result.text.write(to:textFile,atomically:true,encoding:.utf8)
        return textFile
    } catch { try? FileManager.default.removeItem(at:folder); throw error }
}

@MainActor final class ScreenReader:ObservableObject {
    @Published var visible = false
    @Published var targets:[ScreenTarget] = []
    @Published var selected:ScreenTarget?
    @Published var busy = false
    @Published var text = ""
    @Published var status = "选择窗口，再框选需要读取的区域"
    @Published var savedFile:URL?
    @Published var permissionError = false
    @Published var lastError:String?
    @Published var selecting = false
    @Published var preview:NSImage?
    private var regionPanels:[NSPanel] = []
    var captureRegionImage: (UInt32, CGRect) async throws -> Data = { try await captureDisplayRegion(displayID:$0,region:$1) }
    var loadTargets: () async throws -> [ScreenTarget] = { try await visibleScreenTargets() }
    private let storageRoot: URL?
    init(storageRoot: URL? = nil) { self.storageRoot = storageRoot }
    private var savedText: String?
    var resultLabel: String? { pending?.1.label }
    var dirty: Bool { pending != nil && text != savedText }
    private var overlay:NSPanel?
    private var token = UUID()
    private var pending: (ScreenReadResult, ScreenTarget, CGRect)?
    var onNotice:((String)->Void)?
    func open() { visible = true; refresh() }
    func cancel() { token = UUID(); busy = false; selecting = false; overlay?.close(); overlay = nil; regionPanels.forEach { $0.close() }; regionPanels = [] }
    func hide() { cancel(); visible = false }
    func refresh() {
        cancel(); selected = nil; targets = []; busy = true; lastError = nil; permissionError = false
        let session = token
        status = "正在识别当前桌面的窗口…"
        Task {
            defer { if token == session { busy = false } }
            do {
                let windows = try await loadTargets()
                guard session == token else { return }
                targets = windows; status = windows.isEmpty ? "没有可选窗口，请打开应用后刷新" : "选择要框选的窗口"
                if windows.count == 1 { select(windows[0]) }
            } catch { guard session == token else { return }; permissionError = true; lastError = error.localizedDescription; status = "请允许Mo · 墨录制屏幕后刷新" }
        }
    }
    func select(_ target:ScreenTarget) { selected = target; capture() }
    func capture() {
        guard let target = selected else { return }
        if target.pid == 0 { captureRegion(); return }
        cancel(); lastError = nil; busy = true
        let session = token
        status = "正在准备框选画面…"
        Task {
            defer { if session == token { busy = false } }
            do {
                let window = try await resolveScreenWindow(target)
                let (data, _) = try await captureScreenWindow(target,purpose:.ocr)
                guard session == token, let image = NSImage(data:data) else { return }
                let frame = reviewScreenRect(window.frame,desktopTop:NSScreen.screens.first?.frame.maxY ?? 0)
                let panel = IslandPanel(contentRect:frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
                panel.isOpaque = true; panel.backgroundColor = .black; panel.hasShadow = false; panel.hidesOnDeactivate = false
                panel.isReleasedWhenClosed = false; panel.level = .floating
                panel.collectionBehavior = [.fullScreenAuxiliary,.stationary,.ignoresCycle]
                let canvas = ScreenReadCanvas(frame:NSRect(origin:.zero,size:frame.size)); canvas.image = image
                canvas.selected = { [weak self] rect in self?.extract(data:data,region:rect,target:target) }
                canvas.cancelled = { [weak self] in self?.cancel(); self?.status = "已取消框选，可重新框选" }
                panel.contentView = canvas; overlay = panel; panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(canvas)
                selecting = true; status = "在目标窗口上拖动框选 · Esc 取消"
            } catch { guard session == token else { return }; lastError = error.localizedDescription; status = error.localizedDescription }
        }
    }
    private func extract(data:Data, region:CGRect, target:ScreenTarget, sourceRegion:CGRect? = nil) {
        overlay?.close(); overlay = nil; selecting = false; lastError = nil; busy = true
        let session = token; status = "正在识别框选区域…"
        Task {
            defer { if session == token { busy = false } }
            do {
                let result = try await Task.detached(priority:.userInitiated) { try recognizeScreenRegion(png:data,region:region) }.value
                guard session == token else { return }
                accept(result,target:target,region:sourceRegion ?? region)

            } catch { guard session == token else { return }; lastError = error.localizedDescription; status = "识别失败：\(error.localizedDescription)" }
        }
    }
    enum ReplacementChoice { case keep, save, discard }
    // Shared completion path: failed/cancelled captures never reach this point.
    func accept(_ result: ScreenReadResult, target: ScreenTarget, region: CGRect, choice: ReplacementChoice? = nil) {
        guard !result.text.isEmpty else { status = "没有识别到文字，原文字保留"; return }
        guard allowReplacement(choice) else { status = "已保留上次文字"; return }
        savedFile = nil; savedText = nil
        text = result.text; preview = NSImage(data:result.image); pending = (result,target,region)
        save()
    }
    func save() {
        lastError = nil
        guard let (result,target,region) = pending else { return }
        do {
            savedFile = try saveScreenRead(ScreenReadResult(text:text,image:result.image),source:target,region:region,root:storageRoot)
            savedText = text
            status = "已保存：" + (savedFile?.deletingLastPathComponent().lastPathComponent ?? "")
            onNotice?("读屏文字已保存")
        } catch { lastError = error.localizedDescription; status = "保存失败：\(error.localizedDescription)，文字仍保留，可重试保存" }
    }
    func preserveForTermination() -> Bool {
        if dirty { save() }
        return !dirty
    }
    var canRetrySave:Bool { pending != nil && dirty }
    private func allowReplacement(_ choice: ReplacementChoice? = nil) -> Bool {
        guard dirty else { return true }
        if let choice {
            switch choice {
            case .keep: return false
            case .save: save(); return !dirty
            case .discard: return true
            }
        }
        let alert = NSAlert(); alert.messageText = "保留当前未保存文字？"
        alert.informativeText = "另存成功后显示新结果；保留会取消替换。"
        alert.addButton(withTitle:"保留当前"); alert.addButton(withTitle:"另存并继续"); alert.addButton(withTitle:"放弃并继续")
        switch alert.runModal() {
        case .alertSecondButtonReturn: save(); return !dirty
        case .alertThirdButtonReturn: return true
        default: return false
        }
    }
    func captureRegion() {
        cancel(); visible = true; status = "在任意屏幕拖动框选 · Esc 取消"
        for screen in NSScreen.screens {
            let panel = IslandPanel(contentRect:screen.frame,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
            panel.isOpaque = false; panel.backgroundColor = .clear; panel.level = .screenSaver
            panel.isReleasedWhenClosed = false
            let canvas = ScreenReadCanvas(frame:NSRect(origin:.zero,size:screen.frame.size))
            canvas.cancelled = { [weak self] in self?.cancel(); self?.status = "已取消框选，原文字保留" }
            canvas.selected = { [weak self] region in
                guard let self else { return }
                let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
                self.readRegion(displayID:displayID,name:screen.localizedName,region:region)
            }
            panel.contentView = canvas; regionPanels.append(panel); panel.makeKeyAndOrderFront(nil); panel.makeFirstResponder(canvas)
        }
        selecting = true
    }
    func readRegion(displayID: UInt32, name: String, region: CGRect) {
        cancel(); lastError = nil; busy = true; let session = token
        Task {
            do {
                guard session == token else { return }
                let data = try await captureRegionImage(displayID,region)
                guard session == token else { return }
                let target = ScreenTarget(id:displayID,pid:0,app:"屏幕框选",bundleID:"",title:name)
                selected = target
                extract(data:data,region:CGRect(x:0,y:0,width:1,height:1),target:target,sourceRegion:region)
            } catch {
                if session == token { busy = false; lastError = error.localizedDescription; status = "采集失败：\(error.localizedDescription)，原文字保留" }
            }
        }
    }
    func copy(to pasteboard: NSPasteboard = .general) { pasteboard.clearContents(); pasteboard.setString(text,forType:.string); status = dirty ? "文字已复制 · 当前修改未保存" : "文字已复制 · 本地文件已保留" }
    func showLastResult() { if let (_,target,_) = pending { selected = target } }
    func reveal() { if let savedFile { NSWorkspace.shared.activateFileViewerSelecting([savedFile]) } }
}

final class ScreenReadCanvas:NSView {
    var image:NSImage?
    var selected:((CGRect)->Void)?
    var cancelled:(()->Void)?
    private var start:CGPoint?
    private var end:CGPoint?
    override var isFlipped:Bool { true }
    override var acceptsFirstResponder:Bool { true }
    override func resetCursorRects() { addCursorRect(bounds,cursor:.crosshair) }
    override func keyDown(with event:NSEvent) { if event.keyCode == 53 { cancelled?() } else { super.keyDown(with:event) } }
    override func draw(_ dirtyRect:NSRect) {
        image?.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
        NSColor.black.withAlphaComponent(0.2).setFill(); bounds.fill()
        if let start, let end, let normalized = reviewSelection(start,end,size:bounds.size) {
            let r = CGRect(x:normalized.minX*bounds.width,y:normalized.minY*bounds.height,width:normalized.width*bounds.width,height:normalized.height*bounds.height)
            NSGraphicsContext.saveGraphicsState(); NSBezierPath(rect:r).addClip()
            image?.draw(in:bounds,from:.zero,operation:.copy,fraction:1,respectFlipped:true,hints:nil)
            NSGraphicsContext.restoreGraphicsState()
            NSColor.systemBlue.setStroke(); let border = NSBezierPath(rect:r); border.lineWidth = 3; border.stroke()
        }
        let badge = NSRect(x:12,y:12,width:min(320,bounds.width-24),height:30)
        NSColor.black.withAlphaComponent(0.85).setFill(); NSBezierPath(roundedRect:badge,xRadius:7,yRadius:7).fill()
        ("拖动框选需要读取的文字 · Esc 取消" as NSString).draw(in:badge.insetBy(dx:9,dy:7),withAttributes:[.font:NSFont.systemFont(ofSize:12),.foregroundColor:NSColor.white])
    }
    override func mouseDown(with event:NSEvent) { start = convert(event.locationInWindow,from:nil); end = start }
    override func mouseDragged(with event:NSEvent) { end = convert(event.locationInWindow,from:nil); needsDisplay = true }
    override func mouseUp(with event:NSEvent) {
        if let start, let region = reviewSelection(start,convert(event.locationInWindow,from:nil),size:bounds.size) { selected?(region) }
        start = nil; end = nil; needsDisplay = true
    }
}

extension ScreenReader {
    var panelHeight:CGFloat { selected == nil ? 218 + min(240,CGFloat(max(1,targets.count))*64) : 440 }
}
struct ScreenReaderView:View {
    @ObservedObject var reader:ScreenReader
    var body:some View {
        VStack(alignment:.leading,spacing:0) {
            HStack {
                Text("提取文字").font(.system(size:14,weight:.semibold))
                Spacer()
                ToolButton(title:"最近记录",symbol:"clock.arrow.circlepath") { RecordWindows.shared.show() }
                ToolButton(title:"收起读屏面板",symbol:"chevron.up") { reader.hide() }
            }.padding(14)
            Divider()
            HStack(spacing:12) {
                Button { reader.captureRegion() } label: { Label("框选区域",systemImage:"viewfinder") }
                    .buttonStyle(PrimaryActionStyle()).disabled(reader.busy).help("在屏幕上框选文字 · Esc 取消")
                Text(reader.selected == nil ? "或选择一个窗口" : "屏幕模式").font(.system(size:12)).foregroundStyle(IslandStyle.secondary)
                Spacer()
            }.padding(18)
            if reader.selected == nil {
                HStack {
                    Text("可用窗口").font(.system(size:12)).foregroundStyle(IslandStyle.secondary)
                    Spacer()
                    ToolButton(title:"刷新窗口",symbol:"arrow.clockwise") { reader.refresh() }.disabled(reader.busy)
                }.padding(.horizontal,18)
                ScrollView {
                    VStack(spacing:0) {
                        if reader.targets.isEmpty {
                            Label(reader.busy ? "正在查找窗口…" : "暂无可用窗口",systemImage:"macwindow").font(.system(size:14)).foregroundStyle(IslandStyle.secondary).padding(18)
                        }
                        ForEach(reader.targets) { target in
                            Divider()
                            Button { reader.select(target) } label: { ScreenTargetRow(target:target) }
                        }
                    }.padding(.horizontal,18)
                }.frame(height:min(240,CGFloat(max(1,reader.targets.count))*64))
            } else {
                Text(reader.resultLabel ?? reader.selected?.label ?? "屏幕区域").font(.system(size:12)).foregroundStyle(IslandStyle.secondary).lineLimit(2).padding(.horizontal,18)
                TextEditor(text:$reader.text).font(.system(size:14)).scrollContentBackground(.hidden).frame(height:170).padding(12)
                HStack {
                    Button("重新框选") { reader.capture() }.disabled(reader.busy)
                    Button("切换窗口") { reader.refresh() }.disabled(reader.busy)
                    Spacer()
                    if reader.canRetrySave { Button("保存修改") { reader.save() }.buttonStyle(PrimaryActionStyle()) }
                    ToolButton(title:"复制文字",symbol:"doc.on.doc") { reader.copy() }.disabled(reader.text.isEmpty)
                    ToolButton(title:"查看本地文件",symbol:"folder") { reader.reveal() }.disabled(reader.savedFile == nil)
                }.font(.system(size:12)).padding(.horizontal,18).padding(.bottom,10)
            }
            Divider()
            HStack {
                if reader.busy { ProgressView().controlSize(.small) }
                StatusDetails(title:reader.dirty ? "修改未保存" : (reader.busy ? "处理中" : (reader.permissionError ? "需要屏幕权限" : (reader.status.contains("失败") ? "操作未完成" : (reader.selected == nil ? "选择窗口后框选" : "提取状态")))),detail:reader.status)
                Spacer(minLength:4)
                if reader.permissionError { Button("屏幕权限") { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!) } }
                if reader.selected == nil && !reader.text.isEmpty { Button("上次结果") { reader.showLastResult() } }
                if reader.selecting { Button("取消") { reader.cancel(); reader.status = "已取消框选" } }
            }.font(.system(size:12)).foregroundStyle(IslandStyle.secondary).padding(14)
        }.buttonStyle(.plain).modifier(IslandSurface())
    }
}

struct TranscriptFollowState {
    private(set) var following = true
    private(set) var unread = false
    mutating func reading(atBottom: Bool, selecting: Bool) { following = atBottom && !selecting }
    mutating func appended() -> Bool { if !following { unread = true }; return following }
    mutating func resume() { following = true; unread = false }
}
struct TranscriptReader: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> TranscriptScrollContainer { TranscriptScrollContainer() }
    func updateNSView(_ view: TranscriptScrollContainer, context: Context) { view.update(text) }
}
final class TranscriptScrollContainer: NSView, NSTextViewDelegate {
    let scroll = NSScrollView()
    let textView = NSTextView()
    let latest = NSButton(title:"有新内容 · 回到最新",target:nil,action:nil)
    var follow = TranscriptFollowState()
    private var observation: NSObjectProtocol?
    private var updating = false
    override init(frame: NSRect) {
        super.init(frame:frame)
        scroll.hasVerticalScroller = true; scroll.drawsBackground = false
        textView.isEditable = false; textView.isSelectable = true; textView.drawsBackground = false
        textView.font = .systemFont(ofSize:16); textView.textColor = .white
        textView.isVerticallyResizable = true; textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true; textView.autoresizingMask = [.width]
        textView.delegate = self; scroll.documentView = textView; addSubview(scroll)
        latest.target = self; latest.action = #selector(resume); latest.isHidden = true; addSubview(latest)
        scroll.contentView.postsBoundsChangedNotifications = true
        observation = NotificationCenter.default.addObserver(forName:NSView.boundsDidChangeNotification,object:scroll.contentView,queue:.main) { [weak self] _ in
            guard let self, !self.updating else { return }; self.readingChanged()
        }
    }
    required init?(coder: NSCoder) { fatalError() }
    deinit { if let observation { NotificationCenter.default.removeObserver(observation) } }
    override func layout() {
        super.layout(); scroll.frame = bounds
        textView.setFrameSize(NSSize(width:scroll.contentSize.width,height:max(textView.frame.height,bounds.height)))
        latest.frame = NSRect(x:max(0,bounds.width-170),y:0,width:170,height:26)
    }
    func readingChanged() {
        let bottom = scroll.contentView.bounds.maxY >= textView.bounds.maxY - 12
        follow.reading(atBottom:bottom,selecting:textView.selectedRange().length > 0)
        if bottom && follow.following { follow.resume(); latest.isHidden = true }
    }
    func textViewDidChangeSelection(_ notification: Notification) { if !updating { readingChanged() } }
    func update(_ text: String) {
        guard text != textView.string else { return }
        let position = scroll.contentView.bounds.origin; let selection = textView.selectedRange()
        updating = true
        textView.string = text
        textView.setSelectedRange(NSRange(location:min(selection.location,text.utf16.count),length:min(selection.length,max(0,text.utf16.count-selection.location))))
        textView.layoutManager?.ensureLayout(for:textView.textContainer!)
        if follow.appended() { textView.scrollToEndOfDocument(nil) }
        else { scroll.contentView.scroll(to:position); scroll.reflectScrolledClipView(scroll.contentView) }
        latest.isHidden = !follow.unread; updating = false
    }
    @objc func resume() {
        updating = true; textView.setSelectedRange(NSRange(location:textView.string.utf16.count,length:0))
        follow.resume(); textView.scrollToEndOfDocument(nil); latest.isHidden = true; updating = false
    }
}
