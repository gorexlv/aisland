# 交付与安装记录 · 2026-11-05

实现提交：`2c74f4f`。完整保留 CI 改动 `94e4eda`，合并提交为 `10666dd`，验收证据提交为 `d7856d7`。

已在主工作区干净时安全快进并正常推送 `origin/main`，随后 fetch 与 ls-remote 一致确认交付版本 `d7856d7761b484e03e46698969454b9299f6dd6a`，并确认实现提交是该远端提交的祖先。此记录作为后续文档提交，不改变已验收和安装的代码；最终远端 SHA 在协调回报中给出。

## 本机体验

- 安装：`/Applications/Duck Island.app`
- 回滚备份：`/Users/rexlv/Library/Application Support/DuckIsland/Backups/Duck Island-before-native-a-20261105-093856.app`
- 构建：`zsh outputs/DuckIsland/build.sh` 退出 0，复用正式 `sign-local.sh` 身份；未输出密钥或签名材料。
- 旧应用：确认本地备份已保存、没有录制中状态后，通过应用“退出小鸭”正常退出；未强杀、未覆盖运行 bundle。旧版尚未完成的 Notes 同步未作为安装测试重试，本地记录保留。
- 替换：先构建暂存 bundle 并验证签名，再保存旧 bundle 和原子替换；旧版备份仍在。
- 校验：旧/新 bundle `codesign --verify --deep --strict` 均退出 0；designated requirement 比较相同（不记录签名内容）。安装后的同一命令通过。
- 自检：安装后的 `DuckIsland --self-test` 退出 0；句数、OCR fixture、批阅、后台保存、会议 fixture 全部通过。
- 启动：已启动新版本，原生辅助功能树确认“打开功能控制面板”“展开或收起会议文字”。实际点开空会议面板的“会议设置”，AI 开关显示关闭且保留原授权说明；点开“备忘录未同步”，可达保存与恢复详情；最后显示会议/读屏/批阅功能入口。
- 没有启动真实麦克风、屏幕采集、Notes 同步或外部 AI；没有变更 AI 设置或系统权限。

实际多屏硬件和 VoiceOver 未实测，见 [验收报告](VALIDATION.md)。工作 session 与 worktree 保留，由协调者核实远端后清理。
