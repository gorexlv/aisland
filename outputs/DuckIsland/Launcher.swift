import Cocoa
import Combine
import CoreGraphics
import SwiftUI

enum DuckCapability: String, CaseIterable, Identifiable {
    case review, ocr
    var id: String { rawValue }
    var title: String { self == .review ? "批注" : "OCR 读屏" }
    var symbol: String { self == .review ? "square.and.pencil" : "text.viewfinder" }
    var special: Bool { false }
}
func duckCapabilities(for target: ScreenTarget) -> [DuckCapability] { [.review, .ocr] }
func launcherOrderedTargets(_ targets: [ScreenTarget], frontID: UInt32?) -> [ScreenTarget] {
    guard let frontID, let index = targets.firstIndex(where: { $0.id == frontID }) else { return targets }
    var result = targets
    result.insert(result.remove(at: index), at: 0)
    return result
}
func frontmostWindowID(pid: pid_t, among targets: [ScreenTarget]) -> UInt32? {
    guard let info = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else { return nil }
    let ids = Set(targets.map(\.id))
    for window in info {
        guard (window[kCGWindowOwnerPID as String] as? Int32) == pid, (window[kCGWindowLayer as String] as? Int) == 0,
              let number = window[kCGWindowNumber as String] as? UInt32, ids.contains(number) else { continue }
        return number
    }
    return nil
}
func launcherFilteredCapabilities(_ items: [DuckCapability], query: String) -> [DuckCapability] {
    let terms = query.split(whereSeparator: { $0.isWhitespace }).map(String.init)
    return items.filter { item in terms.allSatisfy { item.title.localizedStandardContains($0) } }
}

enum LauncherStep { case window, capability, ready }
@MainActor final class LauncherModel: ObservableObject {
    @Published var step: LauncherStep = .window
    @Published var query = "" { didSet { if query != oldValue { highlight = 0 } } }
    @Published var targets: [ScreenTarget] = []
    @Published var frontID: UInt32?
    @Published var target: ScreenTarget?
    @Published var capability: DuckCapability?
    @Published var highlight = 0
    @Published var status = ""
    @Published var visible = false
    var loadTargets: () async throws -> [ScreenTarget] = visibleScreenTargets
    var onLaunch: (ScreenTarget, DuckCapability, String) -> Void = { _, _, _ in }
    var onClose: () -> Void = {}
    var windowRows: [ScreenTarget] { reviewFilteredTargets(launcherOrderedTargets(targets, frontID: frontID), query: query) }
    var capabilityRows: [DuckCapability] { target.map { launcherFilteredCapabilities(duckCapabilities(for: $0), query: query) } ?? [] }
    private var rowCount: Int { step == .window ? windowRows.count : step == .capability ? capabilityRows.count : 0 }
    private var generation = 0
    func open(frontPID: pid_t?) async {
        generation += 1; let current = generation
        step = .window; query = ""; targets = []; frontID = nil; target = nil; capability = nil; highlight = 0; status = ""; visible = true
        let loaded: [ScreenTarget]
        do { loaded = try await loadTargets() } catch {
            guard current == generation, visible else { return }
            status = "请允许Mo · 墨录制屏幕后重试"; return
        }
        guard current == generation, visible else { return }
        targets = loaded
        if targets.isEmpty { status = "没有可选窗口，请打开应用后重试"; return }
        if let frontPID { frontID = frontmostWindowID(pid: frontPID, among: targets) }
        highlight = 0
    }
    func move(_ delta: Int) { highlight = max(0, min(highlight + delta, max(rowCount - 1, 0))) }
    func confirm() {
        switch step {
        case .window:
            guard windowRows.indices.contains(highlight) else { return }
            target = windowRows[highlight]; query = ""; step = .capability; highlight = 0
        case .capability:
            guard capabilityRows.indices.contains(highlight) else { return }
            capability = capabilityRows[highlight]; query = ""; step = .ready
        case .ready:
            guard let target, let capability else { return }
            onLaunch(target, capability, query.trimmingCharacters(in: .whitespacesAndNewlines)); close()
        }
    }
    func deleteBackward() -> Bool {
        guard query.isEmpty else { return false }
        switch step {
        case .ready: capability = nil; step = .capability; highlight = 0; return true
        case .capability: target = nil; step = .window; highlight = 0; return true
        case .window: return false
        }
    }
    func rewind(to goal: LauncherStep) {
        let rank: (LauncherStep) -> Int = { $0 == .window ? 0 : $0 == .capability ? 1 : 2 }
        query = ""
        while rank(step) > rank(goal), deleteBackward() {}
    }
    func close() { generation += 1; visible = false; onClose() }
}


struct LauncherView: View {
    @ObservedObject var model: LauncherModel
    @FocusState private var focused: Bool
    private var placeholder: String { model.step == .ready ? "补充意图，回车开始" : "想让 Mo 做什么…" }
    private var section: String { model.step == .window ? "第 1 步 · 选择窗口" : "第 2 步 · 选择能力" }
    private func chip(_ text: String, symbol: String?, goal: LauncherStep) -> some View {
        HStack(spacing:4) {
            if let symbol { Image(systemName:symbol).font(.system(size:11,weight:.medium)) }
            Text(text.count > 20 ? String(text.prefix(19)) + "…" : text).font(.system(size:12,weight:.medium)).lineLimit(1).fixedSize()
            Button { model.rewind(to:goal); focused = true } label: { Image(systemName:"xmark").font(.system(size:9,weight:.bold)).foregroundStyle(IslandStyle.secondary) }
                .buttonStyle(.plain).accessibilityLabel("移除 " + text)
        }.padding(.horizontal,8).padding(.vertical,4).background(Color.white.opacity(0.12),in:Capsule())
    }
    private func badge(_ text: String) -> some View {
        Text(text).font(.system(size:10,weight:.medium)).foregroundStyle(IslandStyle.secondary)
            .padding(.horizontal,6).padding(.vertical,2).background(Color.white.opacity(0.1),in:Capsule())
    }
    private func rowBackground(_ index: Int) -> some View { RoundedRectangle(cornerRadius:8).fill(index == model.highlight ? Color.white.opacity(0.1) : .clear) }
    @ViewBuilder private var rows: some View {
        if !model.status.isEmpty {
            Text(model.status).font(.system(size:13)).foregroundStyle(IslandStyle.secondary).frame(maxWidth:.infinity,alignment:.leading).padding(14)
        } else if model.step == .window {
            if model.windowRows.isEmpty { Text("没有匹配的窗口").font(.system(size:13)).foregroundStyle(IslandStyle.secondary).padding(14) }
            else { list(model.windowRows) { index, item in windowRow(index, item) } }
        } else if model.step == .capability {
            if model.capabilityRows.isEmpty { Text("没有匹配的能力").font(.system(size:13)).foregroundStyle(IslandStyle.secondary).padding(14) }
            else { list(model.capabilityRows) { index, item in capabilityRow(index, item) } }
        }
    }
    private func list<T: Identifiable, Row: View>(_ items: [T], @ViewBuilder row: @escaping (Int, T) -> Row) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing:2) {
                    ForEach(Array(items.enumerated()), id:\.element.id) { index, item in
                        row(index, item).id(item.id).contentShape(Rectangle()).onTapGesture { model.highlight = index; model.confirm(); focused = true }
                    }
                }.padding(.horizontal,8)
            }.frame(maxHeight:300).onChange(of:model.highlight) { _, value in
                if items.indices.contains(value) { proxy.scrollTo(items[value].id) }
            }
        }
    }
    private func windowRow(_ index: Int, _ item: ScreenTarget) -> some View {
        HStack(spacing:10) {
            if let icon = NSRunningApplication(processIdentifier:item.pid)?.icon { Image(nsImage:icon).resizable().scaledToFit().frame(width:28,height:28) }
            else { Image(systemName:"macwindow").font(.system(size:20)).frame(width:28,height:28).foregroundStyle(IslandStyle.secondary) }
            VStack(alignment:.leading,spacing:2) {
                Text(item.title.isEmpty ? item.app : item.title).font(.system(size:13)).lineLimit(1)
                Text(item.app).font(.system(size:11)).foregroundStyle(IslandStyle.secondary).lineLimit(1)
            }
            Spacer(minLength:4)
            if item.id == model.frontID { badge("当前") }
        }.padding(.horizontal,8).padding(.vertical,6).background(rowBackground(index))
            .accessibilityElement(children:.combine).accessibilityLabel((item.title.isEmpty ? item.app : item.title) + "，" + item.app + (item.id == model.frontID ? "，当前" : ""))
    }
    private func capabilityRow(_ index: Int, _ item: DuckCapability) -> some View {
        HStack(spacing:10) {
            Image(systemName:item.symbol).font(.system(size:15)).frame(width:28,height:28).foregroundStyle(Color.blue)
            Text(item.title).font(.system(size:13))
            Spacer(minLength:4)
            if let target = model.target, duckCapabilities(for:target).first == item { badge("推荐") }
        }.padding(.horizontal,8).padding(.vertical,6).background(rowBackground(index))
            .accessibilityElement(children:.combine).accessibilityLabel(item.title)
    }
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:8) {
                Image(nsImage:MascotAssets.images["jay"]!).resizable().scaledToFill().frame(width:22,height:22).clipShape(Circle())
                    .overlay(Circle().stroke(.white.opacity(0.5),lineWidth:1)).accessibilityHidden(true)
                if let target = model.target { chip(target.title.isEmpty ? target.app : target.app + " · " + target.title,symbol:nil,goal:.window) }
                if let capability = model.capability { chip(capability.title,symbol:capability.symbol,goal:.capability) }
                TextField(placeholder,text:$model.query).textFieldStyle(.plain).font(.system(size:15)).focused($focused)
                    .onKeyPress(.upArrow) { model.move(-1); return .handled }
                    .onKeyPress(.downArrow) { model.move(1); return .handled }
                    .onKeyPress(.return) { model.confirm(); return .handled }
                    .onKeyPress(.escape) { model.close(); return .handled }
                    .onKeyPress(.delete) { model.deleteBackward() ? .handled : .ignored }
            }.padding(.horizontal,14).frame(height:48)
            if model.step != .ready || !model.status.isEmpty {
                Divider().overlay(IslandStyle.line)
                Text(section).font(.system(size:11,weight:.medium)).foregroundStyle(IslandStyle.secondary)
                    .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16).padding(.top,8).padding(.bottom,4)
                rows
            }
            Divider().overlay(IslandStyle.line).padding(.top,6)
            Text("↩ 选择 · ⌫ 返回 · Esc 关闭").font(.system(size:11)).foregroundStyle(IslandStyle.secondary)
                .frame(maxWidth:.infinity,alignment:.leading).padding(.horizontal,16).frame(height:28)
        }.frame(width:560).modifier(IslandSurface()).onAppear { focused = true }
    }
}

@MainActor final class LauncherPanel: NSObject {
    private let model: LauncherModel
    private var panel: IslandPanel?
    private var observers: [Any] = []
    private var resize: AnyCancellable?
    init(model: LauncherModel) { self.model = model; super.init() }
    var isVisible: Bool { panel?.isVisible == true }
    var window: NSWindow? { panel }
    func show() {
        hide()
        let host = NSHostingView(rootView:LauncherView(model:model))
        let p = IslandPanel(contentRect:NSRect(origin:.zero,size:NSSize(width:560,height:200)),styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        p.isOpaque = false; p.backgroundColor = .clear; p.hasShadow = true; p.hidesOnDeactivate = false
        p.level = NSWindow.Level(rawValue:NSWindow.Level.floating.rawValue+5)
        p.collectionBehavior = [.moveToActiveSpace,.fullScreenAuxiliary,.ignoresCycle]
        p.animationBehavior = .none; p.isReleasedWhenClosed = false
        p.keyInterceptor = { [weak self] event in
            guard event.keyCode == 51, event.modifierFlags.intersection([.command,.option,.control,.shift]).isEmpty else { return false }
            return MainActor.assumeIsolated { self?.model.deleteBackward() == true }
        }
        p.contentView = host; panel = p
        place(p,initial:true)
        resize = model.objectWillChange.sink { [weak self] in DispatchQueue.main.async { if let p = self?.panel { self?.place(p) } } }
        observers = [NotificationCenter.default.addObserver(forName:NSWindow.didResignKeyNotification,object:p,queue:.main) { [weak self] _ in
            MainActor.assumeIsolated { if self?.model.visible == true { self?.model.close() } }
        }]
        p.makeKeyAndOrderFront(nil)
    }
    private func place(_ p: IslandPanel, initial: Bool = false) {
        guard let host = p.contentView as? NSHostingView<LauncherView> else { return }
        let size = host.fittingSize
        if !initial { p.setFrame(NSRect(x:p.frame.midX-size.width/2,y:p.frame.maxY-size.height,width:size.width,height:size.height),display:true); return }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let top = frame.minY + frame.height * 0.72
        p.setFrame(NSRect(x:frame.midX-size.width/2,y:top-size.height,width:size.width,height:size.height),display:true)
    }
    func hide() {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []; resize = nil
        panel?.orderOut(nil); panel?.contentView = nil; panel = nil
    }
}
