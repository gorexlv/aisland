// __MoBridge against a fake __LK page loaded with loadHTMLString: no network, no microphone.
import Cocoa
import WebKit
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)

let page = """
<html><body><button id="wPause">暂停</button><div id="wKbar"></div><script>
window.calls = []; window.sel = -1; window.inBattle = true; window.autoPause = true; window.explode = false; window.explodeOn = -99; window.kingDead = false; window.nearIds = [0, 1];
var kbar = document.getElementById('wKbar'); window.setView = function(king) { kbar.hidden = !king; }; window.setView(true);
var pauseButton = document.getElementById('wPause');
pauseButton.addEventListener('click', function(){ window.calls.push('pause-click'); pauseButton.textContent = pauseButton.textContent === '暂停' ? '继续' : '暂停'; });
var bats = [
  {id: 0, side: 0, name: '剑盾兵1营', typeId: 'swordShield', state: 'fight', type: {}},
  {id: 1, side: 0, name: '弓兵1营', typeId: 'archer', state: 'fight', type: {missile: true}},
  {id: 2, side: 0, name: '骑射营', typeId: 'horseArcher', state: 'fight', type: {missile: true, mounted: true}},
  {id: 3, side: 0, name: '重骑兵', typeId: 'heavyCav', state: 'fight', type: {mounted: true}},
  {id: 4, side: 1, name: '敌军', typeId: 'swordShield', state: 'fight', type: {}},
  {id: 5, side: 0, name: '溃兵', typeId: 'pike', state: 'rout', type: {}},
  {id: 6, side: 0, name: '老"王\\\\营\\'', typeId: 'pike', state: 'fight', type: {}},
  {id: 7, side: 0, name: '没了', typeId: 'pike', state: 'gone', type: {}}
];
window.__LK = {War: {debug: {
  get battle() { return window.inBattle ? {bats: bats} : null; },
  get king() { return {dead: window.kingDead}; },
  select: function(id) { window.calls.push('select:' + id); window.sel = id; if (id >= 0 && window.autoPause && pauseButton.textContent === '暂停') pauseButton.click(); },
  command: function(k) {
    if (window.explode || window.sel === window.explodeOn) throw new Error('boom');
    window.calls.push('command:' + k + '@' + window.sel);
    if (window.sel >= 0) { bats[window.sel].manual = k !== 'auto'; bats[window.sel].order = {kind: k}; }
  },
  quick: function(k) {   // like war.js quick(): silent no-op outside king view, toast when the king is down or nobody is near
    window.calls.push('quick:' + k);
    if (kbar.hidden || window.kingDead) return;
    window.nearIds.forEach(function(id) { bats[id].manual = k !== 'auto'; bats[id].order = {kind: k}; });
  }
}}};
</script></body></html>
"""

final class Loader: NSObject, WKNavigationDelegate {
    var finished = false
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { finished = true }
}

Task { @MainActor in
    let configuration = WKWebViewConfiguration()
    configuration.userContentController.addUserScript(GameBridge.makeUserScript())
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 300), configuration: configuration)
    let window = NSWindow(contentRect: web.frame, styleMask: [.titled], backing: .buffered, defer: false)
    window.contentView = web
    let loader = Loader(); web.navigationDelegate = loader
    func load(_ html: String) async {
        loader.finished = false
        web.loadHTMLString(html, baseURL: nil)
        for _ in 0..<300 where !loader.finished { try? await Task.sleep(nanoseconds: 50_000_000) }
        precondition(loader.finished, "page did not finish loading")
    }
    func calls() async -> [String] {
        let value = try? await web.evaluateJavaScript("JSON.stringify(window.calls)")
        return ((value as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String] }) ?? ["<unreadable>"]
    }
    func script(_ source: String) async { _ = try? await web.evaluateJavaScript(source) }
    func reset(sel: Int = -1, paused: Bool = false) async {
        await script("window.calls = []; window.sel = \(sel); window.inBattle = true; window.explode = false; window.explodeOn = -99; window.kingDead = false; window.nearIds = [0, 1]; window.setView(true); bats.forEach(function(b) { b.manual = false; b.order = {kind: 'idle'}; }); document.getElementById('wPause').textContent = '\(paused ? "继续" : "暂停")';")
    }
    var L: [String] = [], P = ""
    func sync() async { L = await calls(); P = await pausedText() }
    func pausedText() async -> String { (try? await web.evaluateJavaScript("document.getElementById('wPause').textContent") as? String) ?? "?" }

    await load(page)
    let kind = try? await web.evaluateJavaScript("typeof window.__MoBridge") as? String
    precondition(kind == "object", "bridge not injected")

    // state: only my living battalions, shooter / mounted flags, odd name intact.
    var object = await GameBridge.call(web, "state")
    precondition(object["ok"] as? Bool == true && object["inBattle"] as? Bool == true && object["paused"] as? Bool == false, "state \(object)")
    precondition(object["selected"] == nil || object["selected"] is NSNull, "no selection expected: \(object)")
    let bats = GameBridge.parseBats(object)
    precondition(bats.map(\.id) == [0, 1, 2, 3, 6], "bats \(bats.map(\.id))")
    precondition(bats[1].shooter && !bats[1].mounted && !bats[2].shooter && bats[2].mounted && !bats[0].shooter)
    precondition(bats[4].name == "老\"王\\营'", "odd name \(bats[4].name)")

    // run: select + command per battalion, shooters degrade charge -> auto, original selection restored, game not left paused.
    await reset()
    var result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0, 1, 2, 3], "cmd": "charge"]))
    precondition(result.ok && result.done.count == 4 && result.skipped.isEmpty, "run \(result.summary)")
    var log = await calls()
    precondition(log == ["select:0", "pause-click", "command:charge@0", "select:1", "command:auto@1", "select:2", "command:charge@2", "select:3", "command:charge@3", "select:-1", "pause-click"], "charge log \(log)")
    await sync(); precondition(P == "暂停", "game must be running again")
    precondition(result.done[1].cmd == "auto" && result.done[1].from == "charge")

    // skirmish: only horse archers keep it; others advance; shooter that would advance goes auto.
    await reset()
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0, 1, 2], "cmd": "skirmish"]))
    precondition(result.done.map(\.cmd) == ["advance", "auto", "skirmish"], "skirmish \(result.done.map(\.cmd))")
    // retreat / hold are universal.
    await reset()
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [1, 2], "cmd": "retreat"]))
    precondition(result.done.map(\.cmd) == ["retreat", "retreat"])

    // original selection is restored; an already paused game stays paused.
    await reset(sel: 3, paused: true)
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0], "cmd": "hold"]))
    log = await calls()
    // The real game has no selected getter, so the previous pick is unknown: selection is cleared (select(-1)).
    precondition(log == ["select:0", "command:hold@0", "select:-1"], "restore log \(log)")
    await sync(); precondition(P == "继续", "paused game must stay paused")

    // "selected" has nothing to act on without a selected getter.
    await reset(sel: 2)
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": "selected", "cmd": "advance"]))
    await sync()
    precondition(!result.ok && result.message == "没有选中的营" && L.isEmpty)

    // near goes through quick(); unsupported commands are refused without any call.
    await reset()
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": "near", "cmd": "charge"]))
    await sync(); precondition(result.ok && result.message == "已发出" && L == ["quick:charge"], "near \(result.summary)")
    // Repeating the same order changes nothing: reported as not issued instead of a false success.
    await reset()
    await script("bats[0].manual = true; bats[0].order = {kind: 'charge'}; bats[1].manual = true; bats[1].order = {kind: 'charge'};")
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": "near", "cmd": "charge"]))
    precondition(!result.ok && result.message == "国王身边没有可指挥的营", "unchanged near \(result.summary)")
    // Nobody near the king.
    await reset()
    await script("window.nearIds = []")
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": "near", "cmd": "hold"]))
    precondition(!result.ok && result.message == "国王身边没有可指挥的营")
    // King down: refuse before calling quick().
    await reset()
    await script("window.kingDead = true")
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": "near", "cmd": "hold"]))
    await sync(); precondition(!result.ok && result.message.contains("国王倒下") && L.isEmpty)
    // Map view: quick() would silently do nothing, so near is refused with guidance and quick() is never called.
    await reset()
    await script("window.setView(false)")
    object = await GameBridge.call(web, "state")
    precondition(object["kingView"] as? Bool == false && object["inBattle"] as? Bool == true)
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": "near", "cmd": "charge"]))
    await sync(); precondition(!result.ok && result.message.contains("地图视角") && L.isEmpty, "map view \(result.message)")
    // Unit targets still work in map view.
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0], "cmd": "hold"]))
    precondition(result.ok && result.done.count == 1)
    await reset()
    object = await GameBridge.call(web, "state")
    precondition(object["kingView"] as? Bool == true)
    await reset()
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": "near", "cmd": "retreat"]))
    await sync(); precondition(!result.ok && L.isEmpty)
    await reset()
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0], "cmd": "follow"]))
    await sync(); precondition(!result.ok && L.isEmpty, "follow only for near")

    // dead / enemy / unknown ids are skipped with a reason; nothing is selected for them.
    await reset()
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [4, 5, 7, 99], "cmd": "hold"]))
    await sync(); precondition(!result.ok && result.done.isEmpty && result.skipped.count == 4 && L.isEmpty, "skipped \(result.summary)")
    await reset()
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0, 5], "cmd": "hold"]))
    precondition(result.ok && result.done.count == 1 && result.skipped.count == 1)

    // names with quotes / backslashes survive the round trip and do not break the JS.
    await reset()
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [6], "cmd": "hold"]))
    precondition(result.ok && result.done.first?.name == "老\"王\\营'", "odd run \(result.summary)")
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0], "cmd": "ho\"ld');alert(1);//"]))
    precondition(!result.ok && result.message == "不认识的命令", "hostile cmd \(result.message)")

    // inBattle = false: nothing executes.
    await reset()
    await script("window.inBattle = false")
    object = await GameBridge.call(web, "state")
    precondition(object["inBattle"] as? Bool == false && (object["bats"] as? [Any])?.isEmpty == true)
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0], "cmd": "charge"]))
    await sync(); precondition(!result.ok && result.message == "还没开战" && L.isEmpty)
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": "near", "cmd": "charge"]))
    await sync(); precondition(!result.ok && L.isEmpty)

    // exceptions inside the game become {ok:false}.
    await reset()
    await script("window.explode = true")
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0], "cmd": "hold"]))
    precondition(!result.ok && result.message == "boom", "explode \(result.message)")

    // An exception on the second battalion must still restore selection and resume a running game.
    await reset()
    await script("window.explodeOn = 1")
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0, 1, 2], "cmd": "hold"]))
    await sync()
    precondition(!result.ok && result.message == "boom", "mid-loop \(result.message)")
    precondition(L.last == "pause-click" && L.contains("select:-1") && P == "暂停", "mid-loop cleanup \(L) \(P)")

    // pause(bool).
    await reset()
    var pause = await GameBridge.call(web, "pause", true)
    await sync(); precondition(pause["ok"] as? Bool == true && pause["paused"] as? Bool == true && P == "继续")
    pause = await GameBridge.call(web, "pause", true)
    await sync(); precondition(pause["paused"] as? Bool == true && L == ["pause-click"], "pause twice must not toggle back")
    pause = await GameBridge.call(web, "pause", false)
    await sync(); precondition(pause["paused"] as? Bool == false && P == "暂停")

    // a page without __LK (menu / other site): graceful, no crash.
    await load("<html><body>nothing here</body></html>")
    object = await GameBridge.call(web, "state")
    precondition(object["ok"] as? Bool == true && object["inBattle"] as? Bool == false, "no-LK state \(object)")
    result = GameRunResult(await GameBridge.call(web, "run", ["targets": [0], "cmd": "charge"]))
    precondition(!result.ok && result.message == "还没开战")
    pause = await GameBridge.call(web, "pause", true)
    precondition(pause["ok"] as? Bool == false)

    window.close()
    print("PASS: game bridge")
    exit(0)
}
Task { try await Task.sleep(nanoseconds: 60_000_000_000); fatalError("Game bridge test timed out") }
app.run()
