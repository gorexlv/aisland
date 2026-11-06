# Duck Launcher Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A ⌥⇧Enter launcher (window → capability → go) that attaches Mo to the chosen window for 批注 or OCR, replacing the 读屏/批阅 notch entries.

**Architecture:** New `Launcher.swift` holds the capability registry, pure ordering/filtering helpers, `LauncherModel` (keyboard state machine) and its panel/view. New `WindowOCR.swift` holds `WindowOCRSession` (an attached OCR work owning its own `ScreenReader`) plus its panels/orbit/record views, reusing `reviewOrbitLayout` and a shared `MoOrb` view extracted from `ReviewOrbitView`. `Recorder.launch` routes to `ReviewModel.attach` or `WindowOCRSession.attach`, enforcing one attached work at a time.

**Tech Stack:** Swift 6 / SwiftUI + AppKit, ScreenCaptureKit, Vision, Carbon hot keys; tests are `swiftc`-compiled executables with `precondition` (pattern: `tests/run-review-hotkey.sh`).

**Spec:** `docs/superpowers/specs/2026-11-05-duck-launcher-design.md`

## Global Constraints

- macOS 15+, arm64 (`-target arm64-apple-macosx15.0`); no new frameworks, no new permissions.
- Code style matches surrounding code: compact one-line statements, sparse comments, Chinese UI copy.
- Launcher list and capability badges use local rules only — no model calls, no screenshots before a window is chosen.
- Hot keys: ⌥⇧Enter = launcher; ⌥Enter = primary action of current work; ⌥E = end current work.
- One attached work at a time; launching new work saves and ends the old one; Esc on launcher leaves old work untouched.
- Storage formats stay backward compatible: new fields are optional (`StoredReviewSession.intentNote`, `source.json` key `意图`).
- In-app name stays "Mo · 墨"; avatar stays `jay.png`.
- Every new `.swift` file must be added to every hard-coded source list: `outputs/DuckIsland/build.sh`, `scripts/ci/build.sh`, `outputs/DuckIsland/DuckIsland.xcodeproj/project.pbxproj`, `outputs/DuckIsland/Tests/run-*.sh`, `outputs/DuckIsland/Tests/workflow/run.sh`, all `tests/run-*.sh` (find with `grep -rl ReviewOrbit.swift`).
- Do not launch the real app, register real chords, or type into other apps in tests (use F-key chords as `review-hotkey.swift` does).

## Review Focus

1. Frontmost app has no eligible window (Finder desktop, Mo itself) → list still opens, no "当前" row, first row highlighted.
2. Target window closes while launcher is open / between steps → attach reports "选中的窗口已关闭，请重新选择窗口" and launcher stays usable (Task 3 test).
3. Launch new work while review is `busy` or a save fails → old work is not discarded; launch is refused with status message (Task 7 test).
4. OCR with unsaved edits, then ⌥Enter re-frame → existing keep/save/discard path applies; quick-read menu state unaffected (Task 5 test).
5. App quit with attached OCR holding unsaved text → saved before termination (Task 7 test).

---

### Task 1: Capability registry and pure launcher helpers

**Files:**
- Create: `outputs/DuckIsland/Launcher.swift`
- Modify: all source lists listed in Global Constraints (add `Launcher.swift` after `ReviewOrbit.swift`)
- Test: `tests/launcher-logic.swift`, `tests/run-launcher-logic.sh` (copy `run-review-hotkey.sh`, swap test file name)

**Interfaces:**
- Produces:
  - `enum DuckCapability: String, CaseIterable, Identifiable { case review, ocr }` with `var title: String` (`"批注"`, `"OCR 读屏"`), `var symbol: String` (`"square.and.pencil"`, `"text.viewfinder"`), `var special: Bool` (both `false`).
  - `func duckCapabilities(for target: ScreenTarget) -> [DuckCapability]` — applicable capabilities sorted by recommendation; v1 returns `[.review, .ocr]` for every target. Recommended = first element.
  - `func launcherOrderedTargets(_ targets: [ScreenTarget], frontID: UInt32?) -> [ScreenTarget]` — moves the target with `id == frontID` to index 0, keeps others' order.
  - `func frontmostWindowID(pid: pid_t, among targets: [ScreenTarget]) -> UInt32?` — first on-screen layer-0 window of `pid` in `CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID)` order whose id is in `targets`.
  - `func launcherFilteredCapabilities(_ items: [DuckCapability], query: String) -> [DuckCapability]` — all whitespace-split terms must be contained (`localizedStandardContains`) in `title`; blank query returns all.
  - Window filtering reuses existing `reviewFilteredTargets(_:query:)`.

- [ ] **Step 1: Write failing test** `tests/launcher-logic.swift` asserting:
  - `duckCapabilities(for: t).first == .review` and `.count == 2`
  - `launcherOrderedTargets([a,b,c], frontID: c.id).map(\.id) == [c.id, a.id, b.id]`; `frontID: nil` and unknown id keep order
  - `launcherFilteredCapabilities(DuckCapability.allCases, query:"ocr") == [.ocr]`, `query:"批注" == [.review]`, `query:"  "` returns both, `query:"zzz"` empty
- [ ] **Step 2:** `bash tests/run-launcher-logic.sh /tmp/aisland-launcher` → compile FAIL (symbols missing).
- [ ] **Step 3:** Implement the above in `Launcher.swift`; add file to all source lists.
- [ ] **Step 4:** Re-run → prints `PASS: launcher logic`. Also `bash tests/run-review-hotkey.sh /tmp/x` still PASS.
- [ ] **Step 5:** Commit `feat: add duck capability registry and launcher helpers`.

### Task 2: LauncherModel keyboard state machine

**Files:**
- Modify: `outputs/DuckIsland/Launcher.swift`
- Test: extend `tests/launcher-logic.swift`

**Interfaces:**
- Consumes: Task 1 helpers.
- Produces:
  - `enum LauncherStep { case window, capability, ready }`
  - `@MainActor final class LauncherModel: ObservableObject` with `@Published var step: LauncherStep`, `query: String`, `targets: [ScreenTarget]`, `frontID: UInt32?`, `target: ScreenTarget?`, `capability: DuckCapability?`, `highlight: Int`, `status: String`, `visible: Bool`
  - `var loadTargets: () async throws -> [ScreenTarget]` (default `visibleScreenTargets`), `var onLaunch: (ScreenTarget, DuckCapability, String) -> Void`, `var onClose: () -> Void`
  - `var windowRows: [ScreenTarget]` (= `reviewFilteredTargets(launcherOrderedTargets(targets, frontID:), query:)`), `var capabilityRows: [DuckCapability]` (= filtered `duckCapabilities(for: target!)`)
  - `func open(frontPID: pid_t?) async` — resets state, loads targets, sets `frontID` via `frontmostWindowID`, `highlight = 0`; on permission error `status = "请允许Mo · 墨录制屏幕后重试"`; empty → `status = "没有可选窗口，请打开应用后重试"`.
  - `func move(_ delta: Int)` (clamped), `func confirm()`, `func deleteBackward() -> Bool` (returns `true` if it consumed the key: only when `query` is empty and a tag exists), `func close()`
  - `confirm()` semantics: `.window` → set `target`, clear query, step `.capability`, `highlight = 0`; `.capability` → set `capability`, clear query, step `.ready`; `.ready` → `onLaunch(target, capability, query.trimmed)` then `close()`. Confirm on empty rows does nothing.
  - `deleteBackward()` at `.ready` → drop capability, step `.capability`; at `.capability` → drop target, step `.window`.
  - Changing `query` resets `highlight` to 0 (didSet).

- [ ] **Step 1: Failing tests** (inject `loadTargets` returning 3 fixture targets, call `open(frontPID:nil)`, set `frontID` manually):
  - Fast path: `confirm(); confirm(); confirm()` → `onLaunch` called once with `(rows[0], .review, "")`, `visible == false`
  - Note: after two confirms set `query = " 看下标题 "` then `confirm()` → note `"看下标题"`
  - `query = "ocr"` at capability step → `capabilityRows == [.ocr]`, `highlight == 0`
  - `deleteBackward()` with non-empty query returns `false`; with empty query at `.ready` returns `true` and step is `.capability`; again → `.window`, `target == nil`
  - `move(5)` clamps to last row; `move(-9)` to 0
  - `loadTargets` throwing → `status` contains `"录制屏幕"`; empty list → `status == "没有可选窗口，请打开应用后重试"` and `confirm()` does not call `onLaunch`
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS.
- [ ] **Step 5:** Commit `feat: add launcher keyboard state machine`.

### Task 3: ReviewModel attach, intent note, standalone restore

**Files:**
- Modify: `outputs/DuckIsland/ReviewModel.swift`, `outputs/DuckIsland/ReviewExport.swift`, `outputs/DuckIsland/ReviewPanels.swift` (show note atop record panel)
- Test: `tests/review-attach.swift`, `tests/run-review-attach.sh`

**Interfaces:**
- Produces:
  - `ReviewModel.intentNote: String` (`@Published`, default `""`); `StoredReviewSession.intentNote: String? = nil`, written in `persist`, read in `restore`.
  - `func reviewExportTitle(_ label: String, note: String) -> String` in `ReviewExport.swift` → `label` if note blank, else `label + "\n意图：" + note`. Use at the copy (`ReviewModel.swift:629`), notes write (`:506` body title source), persist text (`:664`) and Claude/Codex send paths. **Not** in `summarySourceJSON` / `summarizeReview`, and not in the live-chat context.
  - `func attach(_ item: ScreenTarget, note: String) async -> Bool` — if not active: perform `start` state reset without scanning or showing the picker sidebar, set `picking = true`, `intentNote = note`, then `await choose(item)` (which auto-enters review). Returns `false` (and leaves `status` with the error) if `choose` failed. Must not call `panels.showTargetPicker()`/`showHighlights`.
  - `func restoreLatestStandalone() async` — guard `!active, !busy`; find `store.latest(root:)`; none → `status = "没有可恢复的批阅"`; else `try await restore(folder:)`.
- [ ] **Step 1: Failing tests** (fixture target with `pid:-1` like `review-orb-entry.swift`, temp `storageRoot`):
  - `reviewExportTitle("A", note:"") == "A"`; `reviewExportTitle("A", note:"看标题") == "A\n意图：看标题"`
  - Encode `StoredReviewSession` with `intentNote:"x"` → decode equals; decoding legacy JSON without the key → `intentNote == nil`
  - `attach` to a target whose window cannot be resolved → returns `false`, `status == "选中的窗口已关闭，请重新选择窗口"`, `panels.sidebar` is not showing a picker (`picking` may stay true but `targets` stays empty and no highlights)
  - `summarySourceJSON` unaffected by `intentNote`
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** Run → PASS; also `run-review-recovery.sh`, `run-review-claude.sh`, `run-review-ai-summary.sh` PASS.
- [ ] **Step 5:** Commit `feat: attach review directly to a launcher-chosen window`.

### Task 4: Extract shared MoOrb view

**Files:**
- Modify: `outputs/DuckIsland/ReviewOrbit.swift`
- Test: existing `tests/run-review-orb-entry.sh`, `tests/run-review-orbit.sh`

**Interfaces:**
- Produces: `struct MoOrb: View { let ringColor: Color; let busy: Bool; let listening: Bool }` — the 76×76 ring+avatar+"Mo" label currently inside `ReviewOrbitView`'s center button label (TimelineView included). `ReviewOrbitView` uses it unchanged in behavior.
- [ ] **Step 1:** Run both orb tests before refactor, keep PNGs from `/tmp/orb-before`.
- [ ] **Step 2:** Extract `MoOrb`; run tests to `/tmp/orb-after`; both PASS and `orb-empty-dark.png` visually identical (compare with `cmp` or note pixel diff).
- [ ] **Step 3:** Commit `refactor: extract MoOrb avatar view`.

### Task 5: WindowOCRSession model

**Files:**
- Create: `outputs/DuckIsland/WindowOCR.swift` (add to all source lists)
- Modify: `outputs/DuckIsland/ScreenReader.swift`
- Test: `tests/window-ocr.swift`, `tests/run-window-ocr.sh`

**Interfaces:**
- Consumes: `ScreenReader`, `MoLiveSession`, `VoiceInput`.
- Produces:
  - `saveScreenRead(_:source:region:root:note:)` — new trailing `note: String = ""`; when non-blank adds `"意图": note` to `source.json`.
  - `ScreenReader.note: String` (passed to `saveScreenRead`), `ScreenReader.onSaved: ((URL, String) -> Void)?` called after every successful `save()` with `(textFile, text)`.
  - `struct WindowOCRRecord: Identifiable { let id: UUID; let file: URL; var text: String; let date: Date }`
  - `@MainActor final class WindowOCRSession: ObservableObject` with `let reader: ScreenReader` (own instance, `init(storageRoot: URL? = nil)`), `@Published var active: Bool`, `target: ScreenTarget?`, `note: String`, `records: [WindowOCRRecord]`, `speakingEnabled: Bool` (default `false`), `status: String`; `let live: MoLiveSession`, `let voice: VoiceInput` (shared from `ReviewModel` — injected in init); `var panels: WindowOCRPanels` (Task 6, may be a stub here).
  - `func attach(_ item: ScreenTarget, note: String) async -> Bool` — resolve window (failure → status `"选中的窗口已关闭，请重新选择窗口"`, return `false`), set state, start 0.8 s tracking, then `reframe()` (immediate framing).
  - `func reframe()` — `reader.select(target)` (reuses existing keep/save/discard confirmation via `accept`).
  - `var latestText: String` (= `reader.text`).
  - `func setSpeakingEnabled(_ on: Bool)` — `on` with blank `latestText` → no-op with `status = "请先框选识别文字"`; else `live.start(context: "OCR 识别文字（\(target.label)）：\n" + latestText, deviceID:)`; `off` → `live.stop()`. On each new save while speaking, restart live with new context.
  - `func end() async -> Bool` — if `reader.dirty`, `reader.save()`; if still dirty return `false` with status kept; stop live, invalidate tracking, `reader.cancel()`, close panels, reset state, return `true`.
  - `func preserveForTermination() -> Bool` → `reader.preserveForTermination()`.
- [ ] **Step 1: Failing tests** (temp storage root; drive `reader.accept(ScreenReadResult(...), target:, region:, choice:)` directly, no screen capture):
  - `saveScreenRead(..., note:"查标题")` → `source.json` decodes with `"意图" == "查标题"`; without note no `意图` key
  - With session active + note set, two `accept` calls (`choice: .discard` for the second) → `records.count == 2`, each `file` exists, newest last
  - Empty-text result → no record added, status `"没有识别到文字，原文字保留"`
  - Two sessions/readers are independent: `WindowOCRSession.reader !== recorder.screenReader`; dirtying one leaves `dirty == false` on the other
  - `setSpeakingEnabled(true)` with no text → `speakingEnabled == false`, status `"请先框选识别文字"`
  - `end()` with dirty text and a read-only storage root → returns `false`; with writable root → `true`, `active == false`
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement (stub `WindowOCRPanels` with no-op `attach/close/refresh` if Task 6 not done). **Step 4:** PASS; `run-recent-records.sh` still PASS.
- [ ] **Step 5:** Commit `feat: add attached window OCR session`.

### Task 6: WindowOCR panels, orbit and record views

**Files:**
- Modify: `outputs/DuckIsland/WindowOCR.swift`
- Test: `tests/window-ocr-render.swift`, `tests/run-window-ocr-render.sh` (render PNGs like `review-orb-entry.swift`)

**Interfaces:**
- Consumes: `reviewOrbitLayout`, `reviewScreenRect`, `MoOrb`, `ReviewControlsHostingView`, `IslandPanel`, `ScreenReaderView` styling helpers (`IslandStyle`, `ToolButton`).
- Produces:
  - `@MainActor final class WindowOCRPanels` — `position(_ windowFrame: CGRect)`, `hideForWorkspace()`, `close()`, `moveOrb(to:)`; holds `toolbar` (controls at `layout.controls`) and `record` panel (at `layout.preview`, size per `reviewOrbitLayout`), relative position default `CGPoint(x:0.88,y:0.78)` like review.
  - `struct WindowOCROrbitView: View` — 128×124, same positions as `ReviewOrbitView`: center `MoOrb` (click → `reframe()`, drag → `moveOrb`), left 28 pt button `list.bullet.rectangle` (popover listing `records`: text first line + time; actions 复制 / 在 Finder 中显示 / 重新框选), right speaker button identical styling to review (disabled + help `"请先框选识别文字"` when no text). Context menu: `重新框选`, `查看记录（n）`, `结束并撤下`.
  - `struct WindowOCRRecordView: View` — note line `意图：…` when non-empty; editable `latestText` (bound to `reader.text`); status line; buttons 复制 / 重试保存 (when `reader.canRetrySave`) / 定位文件; when `live.active` shows `live.messages` below.
- [ ] **Step 1:** Write render test producing `ocr-orb-dark.png`, `ocr-orb-light.png`, `ocr-record-dark.png` (with note + fixture text) and asserting toolbar `contentView.acceptsFirstMouse(for:nil)`; clicking the orb (synthesized mouse events as in `review-orb-entry.swift`) increments a `reframe` counter (inject `var reframeAction`).
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** PASS; inspect PNGs visually against `orb-empty-*.png` from Task 4.
- [ ] **Step 5:** Commit `feat: attach Mo orb and record panel for window OCR`.

### Task 7: Wiring — launcher panel, hot keys, menu, notch, routing, termination

**Files:**
- Modify: `outputs/DuckIsland/Launcher.swift` (panel + view), `outputs/DuckIsland/main.swift`, `tests/ux-render.swift`, `outputs/DuckIsland/Tests/PredictableActions.swift`, `outputs/DuckIsland/Tests/workflow/checks.swift` (only where they reference removed buttons/menu titles)
- Test: `tests/launcher-routing.swift`, `tests/run-launcher-routing.sh`

**Interfaces:**
- Consumes: Tasks 2, 3, 5, 6.
- Produces:
  - `struct LauncherView: View` — layout A from spec: input row (Mo avatar 22 pt, tag chips for target/capability, `TextField` placeholder `"想让 Mo 做什么…"` / at `.ready` `"补充意图，回车开始"`), section label `"第 1 步 · 选择窗口"` / `"第 2 步 · 选择能力"`, rows (window: app icon, title, app name, `"当前"` badge on `frontID`; capability: symbol, title, `"推荐"` on index 0 of unfiltered list), footer `"↩ 选择 · ⌫ 返回 · Esc 关闭"`. Clicking a row = set `highlight` + `confirm()`; clicking a tag chip's × = `deleteBackward()` back to that step. Permission/empty `status` shown in place of rows. Keys via `.onKeyPress` for up/down/return/escape and delete (delete only consumed when `deleteBackward()` returns true). Width 560, centered on active screen, `IslandStyle` colors.
  - `@MainActor final class LauncherPanel` — owns an `IslandPanel` (`.moveToActiveSpace`, level floating+5), `show()` makes it key and focuses the field; `hide()`; closes on resign key.
  - `Recorder.windowOCR: WindowOCRSession`, `Recorder.launcher: LauncherModel`
  - `func Recorder.openLauncher()` — records `NSWorkspace.shared.frontmostApplication?.processIdentifier` **before** showing the panel, then `await launcher.open(frontPID:)`.
  - `func Recorder.launch(_ target: ScreenTarget, _ capability: DuckCapability, note: String) async` — guard `!terminationRequested`; `guard await endCurrentWork() else { toast "当前工作保存失败，未切换"; return }`; then `review.attach` or `windowOCR.attach`.
  - `func Recorder.endCurrentWork() async -> Bool` — review active → `await review.closeForTermination()` (returns false if busy/failed); OCR active → `await windowOCR.end()`; none → true.
  - `func Recorder.primaryAction()` (⌥Enter) — OCR active → `windowOCR.reframe()`; else existing `toggleReviewShortcut()`.
  - `func Recorder.restoreLatestReview()` — `guard await endCurrentWork()` then `review.restoreLatestStandalone()`.
- AppDelegate changes:
  - `reviewHotKey.start(action: primaryAction, detach: { Task { _ = await endCurrentWork() } }, picker: openLauncher)`.
  - Menu: `"唤起 Mo　⌥⇧ Enter"` (fallback `"唤起 Mo（快捷键不可用）"`) → `openLauncher`; `"当前工作主操作　⌥ Enter"`; `"结束当前工作　⌥ E"`; add `"恢复最近批阅"` → `restoreLatestReview`; keep `"快捷框选取字"` and the rest.
  - Review orbit context menu: add `"恢复最近批阅"` only when no snapshots exist (calls `Recorder.restoreLatestReview` via a closure on `ReviewModel`, e.g. `var onRestoreRequest: (() -> Void)?`).
  - `IslandView` menu row: remove 读屏 and 批阅 buttons; keep 会议.
  - Termination (`requestTermination`): before review close, `guard model.windowOCR.preserveForTermination()` (same alert path as `screenReader`), then `await model.windowOCR.end()`.
- [ ] **Step 1: Failing tests** `tests/launcher-routing.swift` (no real windows: inject `review`/`windowOCR` attach closures or fixture targets with `pid:-1`):
  - `launch(t, .ocr, note:"n")` while review active+`busy` → review untouched, OCR not attached, toast `"当前工作保存失败，未切换"`
  - `launch(t, .review, ...)` while OCR active with clean reader → `windowOCR.active == false` afterwards and review attach was invoked with note
  - `primaryAction()` with OCR active calls `reframe` (counter), otherwise toggles review
  - Render `IslandView` with `showMenu = true` → only one feature button (assert via accessibility label `"会议"` present, `"读屏"`/`"批阅"` absent in `ux-render.swift`)
  - Termination with OCR dirty + writable root → saved; read-only root → termination cancelled
- [ ] **Step 2:** Run → FAIL. **Step 3:** Implement. **Step 4:** PASS; then update and run `ux-render`, `review-hotkey` (menu titles), `PredictableActions`, workflow checks.
- [ ] **Step 5:** Commit `feat: route launcher to attached review and OCR work`.

### Task 8: Full regression and build

- [ ] **Step 1:** Run every `tests/run-*.sh` and `outputs/DuckIsland/Tests/run-*.sh`, `outputs/DuckIsland/Tests/workflow/run.sh`; all PASS (record any pre-existing failures from baseline commit `8b40dc6` separately).
- [ ] **Step 2:** `cd outputs/DuckIsland && ./build.sh` compiles and signs (do not launch).
- [ ] **Step 3:** Update `outputs/DuckIsland/README.md`: replace the 树袋熊/鹦鹉 entry descriptions with the launcher flow (⌥⇧Enter → 窗口 → 能力 → 回车; OCR attach behavior; 恢复最近批阅 location).
- [ ] **Step 4:** Commit `docs: describe window-first launcher`.
