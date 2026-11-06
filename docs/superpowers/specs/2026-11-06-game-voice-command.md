# 陪玩 · 守城小国王：语音指挥（第一版）

日期：2026-11-06 · 范围：`outputs/DuckIsland` · 分支 `gorexlv/game-voice`

## 用户决定
- 方式 A：aisland 自己开窗口内嵌游戏（WKWebView），小墨挂在这个窗口上，通过 `evaluateJavaScript` 调游戏的 `window.__LK` 接口。
- 先做**语音指挥**：用户说话 → 小墨把话变成游戏命令执行。托管代打、小墨当对手以后再做。

## 游戏事实（源码 `~/orca/workspaces/giant-game/copepod/little-king/war.js`，只读参考，不改游戏）
- 正式版 `https://little-king.vercel.app`；测试版 `https://little-king-git-war-mode-sheji.vercel.app`；本地 `http://127.0.0.1:8940/little-king/`。
- `window.__LK.War.debug`（会战/亲征时可用）：
  - `battle` → 当前战斗 `bt`（`bt.bats[i]`：`id`、`side`(0=我方)、`name`（如「剑盾兵1营」「重骑兵」）、`typeId`、`state`（`gone`/`rout` 表示没了/溃逃）、`type.mounted`、`type.missile`）
  - `select(id)` 选中我方营；`command(k)` 对**当前选中营**下命令，`k ∈ hold advance charge skirmish retreat auto`
  - `quick(kind)` 对**国王身边的营**下命令，`kind ∈ follow charge hold auto`（会自己 toast 提示「身边没有营」等）
  - 每营可用命令 `cmdsOf(b)`：`hold`；非射手加 `advance charge`；`horseArcher` 加 `skirmish`；都有 `retreat auto`。射手 = 有 `missile` 且不骑马。
- 兵种 typeId：`heavyShield swordShield pike archer crossbow heavyCav horseArcher`。
- 游戏可能在菜单/布阵页（`debug.battle` 为空）：此时指令提示「还没开战」，不执行。暂停按钮 id `wPause`。

## 需求
1. **游戏窗口** `GameWindow`（新文件 `GameCompanion.swift`）：标准 NSWindow（可缩放，标题「守城小国王 · 小墨陪玩」），WKWebView 加载设置里的地址（默认正式版）；菜单栏新增「陪玩 · 守城小国王」打开它。设置窗口新增「陪玩」分区：游戏地址（下拉三个预设 + 自定义）、「语音回应」开关（默认开）。
2. **小墨挂上去**：复用 `OrbitPanels`/`MoOrb`（同 WindowOCR/LarkProxy 的布局与跟随）；左按钮 = 打开/收起指令记录；右按钮 = 麦克风开关（默认关，点开开始听）；头像点击 = 开/关听。窗口关闭即撤下并停止听。与启动器的「一次只一个 attach 工作」规则共存：打开游戏窗口前先结束当前工作（复用 `Recorder.endCurrentWork`）。
3. **桥接脚本**：`WKUserScript`（documentEnd，main frame）注入 `window.__MoBridge`：
   - `state()` → `{ok, inBattle, paused, selected, bats:[{id,name,typeId,shooter,mounted,alive}]}`（只我方、未 gone/rout）
   - `run({targets:[id…]|"near"|"selected", cmd})` → 逐营 `select(id)` + `command(k)`；命令该营不支持时按游戏规则降级（射手的 charge/advance → auto；非骑射的 skirmish → advance）；`"near"` 走 `quick`；最后恢复原选中；返回 `{ok, done:[{name,cmd}], skipped:[{name,reason}], message}`。
   - `pause(bool)` 点 `wPause` 切换。
   - 所有异常捕获返回 `{ok:false,message}`。Swift 侧只传 JSON（`JSONSerialization` 编码参数），不拼接用户原话进 JS。
4. **语音识别**：新的轻量识别器（不复用批注的 VoiceInput 状态，但可复用其设备/权限辅助）：`SFSpeechRecognizer(zh-CN)`，优先本机识别，`contextualStrings` 填命令词与当前各营名字；连续听，按句子定稿（`isFinal` 或 0.8 s 无新字）后交给解析器；静默中不发任何网络请求。会议录音或 GPT-Live 占用麦克风时拒绝开启并提示原因（同现有互斥）。
5. **指令解析器**（纯函数，`func gameParseCommand(_ text:String, bats:[GameBat]) -> GameIntent?`）：
   - 去掉「小墨小墨」及同音前缀（复用 `moPinyin` 判断）。
   - 对象：全军/所有/全体/大家 → all；骑兵 → heavyCav+horseArcher；重骑 → heavyCav；骑射 → horseArcher；步兵 → heavyShield+swordShield+pike；盾兵/剑盾 → swordShield(+heavyShield 对「盾」)；长枪/枪兵 → pike；弓兵/弓箭手/射手 → archer+crossbow；弩兵 → crossbow；营名精确匹配（「剑盾兵一营」中文数字转阿拉伯）；身边/附近 → near。
   - 命令：冲锋/冲/杀/进攻 → charge；前进/推进/压上 → advance；坚守/守住/顶住/停下 → hold；撤退/后撤/退回 → retreat；风筝/放风筝/游击 → skirmish；交给副将/自由/自动 → auto；跟我来/跟上/跟着我 → follow（只对 near）；暂停/继续 → pause/resume。
   - 无对象：有选中营 → selected；否则 → near（只对 charge/hold/follow/auto；其余无对象则视为 all）。
   - 解析不出命令 → nil（界面显示「没听懂：…」，不执行）。
6. **反馈**：记录面板（OrbitPanels 的 record 区）逐条：时间、「你说」、「执行」结果或跳过原因；状态行显示「在听」/「还没开战」等。语音回应用 `AVSpeechSynthesizer`（zh-CN，短句如「骑兵冲锋」），开关在设置；回应播放时暂停识别避免自听。

## 测试（不联网、不开麦）
- `tests/game-command.swift`：解析器表驱动 ≥30 条（含同音/口语：「小莫小莫骑兵冲锋」「全军撤退」「弓箭手坚守」「剑盾兵一营前进」「跟我来」「暂停」「随便说说」→nil）。
- `tests/game-bridge.swift`：WKWebView `loadHTMLString` 一个假页面（定义假的 `__LK.War.debug` 记录调用），注入桥接脚本，断言 `run` 的调用序列、降级、恢复选中、`inBattle=false` 时不执行、参数里含引号/反斜杠的营名不破坏 JS。
- 渲染游戏窗口小墨面板 PNG（带几条记录）自己看。
- 跑 launcher-routing、settings、window-ocr、lark-proxy、build.sh。
