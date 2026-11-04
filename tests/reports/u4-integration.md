# U4 交互优化集成验收

日期：2026-11-05。基线 origin/main `08275f59b1655aae407e9c1265314baf4415536b`；分支 gorexlv/ux-integration。真实 merge 保留 U1 fd7660a、U2 51d00a3、U3 a9aadea 的祖先关系；合并提交分别为 8956fce、023f004、755c55a。

## 合并与修复

- main.swift 人工整合 U1 重复会议入口只开面板、录制时间，U2 双版本披露/结果/AI 开关，U3 麦克风占用与 OCR/文字批阅并行；停止清理同时清除 recordingStartedAt 和 microphoneReserved。
- 菜单高度保留138、结果区408、录制栏44；OCR/批阅按钮只因退出而禁用，会议入口继续防重复。
- ReviewPanels 两处语音可用性自动合并后复核，保留 U1 删除/撤销/单击只选中。
- RecentRecords 已注册 build.sh、Xcode 和全部实际需要的测试源码清单；补齐 U1/U3 脚本引用。git tracked 路径按小写归一检查无大小写碰撞；tests 与 outputs/DuckIsland/Tests 位于不同目录，不新建同目录 tests/Tests。
- 修复主面板及右键复制遗漏独立 warning：复制原文附带记录状态，成功状态取实际 pasteboard 写入返回值；加生产 Recorder 私有状态同文件 extension 测试，使用独立剪贴板。
- 为会议/OCR 收起图标补充可访问名称。

## 组合验收矩阵

| 项 | 证据与结果 |
| --- | --- |
| 1 黄鸭、结束幂等、时长 | U1 实际 Recorder toggle/meeting/重复 stop 测试通过；开始赋 Date、停止清空；虚构录制菜单渲染显示02:05、结束会议、三工具入口；收起仅改面板状态。真实计时/菜单点击未测。 |
| 2 并行工具/麦克风互斥 | U3 实际 recording+transcript 状态调用 readScreen/startReview 保留会议；准备/录制/收尾三态阻止会议，microphoneReserved 阻止批阅语音且显示原因；U1 单击/跨截图语音屏障测试通过。 |
| 3 删除撤销/恢复/兼容 | U1 删除截图/标记、撤销、跨截图晚到语音、清空重开、保存失败保留通过；新增实际 ReviewStore→RecentRecords 检查最终意见；version1 删除 capturedAt JSON 字段仍解码 nil；已有 capturedAt 往返断言。复制不关闭，关闭等待保存。 |
| 4 OCR和三种退出屏障 | U3 编辑后复制/保存、取消/空结果/失败保留、原图片与区域元数据通过；新增屏幕来源保存断言，窗口来源原断言保留。扩展实际 AppDelegate 测试：OCR失败先拒绝退出且批阅语音/会议未停止→修复OCR磁盘→批阅语音结束及保存失败拒绝→修复磁盘→会议退出等待超时不取消识别→排空后重试成功；重复退出无重复回调。生产默认12秒，测试缩短预算为0.05秒验证相同路径，未实际等待12秒硬件收尾。 |
| 5 三类历史/旧回调 | U2 两版磁盘重新加载、损坏UTF8、旧格式、空记录、原文/总结/待办范围通过，历史Notes未知；新增U1最终意见与U3编辑OCR通过真实扫描可找回；capturedAt保留在manifest供恢复，历史窗口不声称可编辑或显示该时间；既有跨会话保存/识别测试通过。 |
| 6 AI/警告/跟随 | U2 两版关闭AI零调用、APP_STORE请求分析也零调用通过；首次披露代码双版本可达。状态/最终落盘/结果原文保留警告，新增主面板复制警告断言通过。实际AppKit文字视图上滚/选择保持位置与选择、恢复跟随测试通过。 |
| 7 离线视觉与可访问性 | 新 tests/run-ux-render.sh 编译生产 IslandView/ScreenReaderView，离屏 NSHostingView cacheDisplay，仅虚构文本/白图/资源图，不截桌面。人工查看三张PNG：菜单按钮、结束按钮可见；长标题截断不挤走操作，结果多错误和底部复制/收起完整；录制+OCR编辑、保存修改/复制/查看文件及错误完整。仅暗色生产面板固定尺寸审查，不代表真实窗口定位或辅助技术体验。 |

## 最终验证（全部 exit 0）

- `bash outputs/DuckIsland/Tests/run-predictable-actions.sh`
- `bash tests/run-recent-records.sh`（local/store）
- `bash outputs/DuckIsland/Tests/workflow/run.sh`（含既有虚构 OCR/Review/后台保存/会议 self tests）
- `bash outputs/DuckIsland/Tests/run-save-reliability.sh`（local/store故障矩阵、两版完整无签名构建、NotesHelper）
- `zsh outputs/DuckIsland/Tests/meeting/run.sh`
- `bash tests/run-review-recovery.sh`
- `bash tests/run-integration-termination.sh`
- `bash tests/run-ux-render.sh`
- outputs/DuckIsland 下按 build.sh 全部14个生产 Swift 文件及其全部 framework/arm64 macOS15 target 执行 `swiftc -O` 编译链接至 `/tmp/u4-validation/DuckIsland-release`；未运行 build.sh/sign-local.sh。
- `xcodebuild -project outputs/DuckIsland/DuckIsland.xcodeproj -scheme DuckIsland -configuration Release -derivedDataPath /tmp/u4-store CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build`：BUILD SUCCEEDED；APP_STORE 条件未移除，产物内嵌 NotesHelper。二进制不含 `/opt/homebrew/bin/codex` 或 `--ignore-user-config`。
- `git diff --check` 通过。

最终测试输出与PNG在 `tests/reports/u4-evidence/`；完整Xcode日志 `/tmp/u4-validation/xcode.log`，普通Release日志 `/tmp/u4-validation/release.log`。首轮因源文件在编译中修改而失败；新复制签名造成旧action回调类型错误；测试访问private以及渲染尝试写只读环境值造成编译错误，全部修复并重跑相关完整套件，不计非零为通过。

## 未测边界

未真实录音、采集私人桌面、执行Notes写入、外部AI或签名脚本。真实菜单/Esc按键、混合DPI/多屏/全屏空间、权限拒绝撤销、VoiceOver、触控板与硬件音频持续性、首次披露弹窗点击及沙盒授权仍需专用非私人桌面设备验收；历史恢复用重新读取磁盘模拟重启，未实际重启GUI应用。未声称构建等于可用性验收；本次离屏图未覆盖独立最近记录窗口及批阅窗口所有布局。

## 发布核验

提交报告后重新fetch；只有主工作区干净、main可快进时执行 `git merge --ff-only gorexlv/ux-integration`，再普通 `git push origin refs/heads/main:refs/heads/main`。实际远端SHA、四个祖先检查及所有worktree状态写入 `/tmp/u4-validation/publish-evidence.txt` 并随worker_done汇报；本报告本身不预先声称推送成功。所有session/worktree及源分支保留，由PM收到远端证据后清理。
