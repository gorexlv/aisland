# aisland · 小鸭 Duck Island

原生 macOS 顶部灵动岛工具：会议转写、框选读屏和截图批阅，搭配动物挂件与轻微动效。

## 环境

- Apple Silicon Mac，macOS 15 或更新版本
- Xcode 和 macOS SDK（安装后完成首次启动配置）
- 直接分发版的会议总结需要已安装并登录的 Codex CLI

## 源码

源码、素材与 Xcode 工程位于 [`outputs/DuckIsland`](outputs/DuckIsland)。

- 会议：系统音频与麦克风转写，后台保存文字并写入 Apple 备忘录。
- 读屏：选择窗口与区域，使用本机 Vision OCR 保存图片与文字。
- 批阅：每次暂停保留完整截图，多区域标注及语音意见，支持图文复制。
- 直接分发版包含 Codex 总结；App Store 基础版通过 `APP_STORE` 编译配置排除 AI 总结与外部 CLI。

## 构建

App Store 基础版：

```sh
open outputs/DuckIsland/DuckIsland.xcodeproj
```

选择 `DuckIsland` scheme；在 Signing 中选择自己的开发团队。仓库中保留原发布团队配置，签名证书及私钥不在仓库中。

仅编译、不签名：

```sh
xcodebuild -project outputs/DuckIsland/DuckIsland.xcodeproj -scheme DuckIsland -configuration Debug -derivedDataPath /tmp/aisland-build CODE_SIGNING_ALLOWED=NO build
```

直接分发版：

```sh
cd outputs/DuckIsland
./build.sh
```

脚本创建 `outputs/Duck Island.app`，并运行自检。首次本地签名会创建专用钥匙串和代码签名证书，后续构建复用身份以保持系统权限稳定。签名资料保存在用户 Application Support 下，不应提交。

App Store 归档：

```sh
DEVELOPMENT_TEAM=YOUR_TEAM_ID ./outputs/DuckIsland/AppStore/archive.sh
```

导出与上传配置在 `AppStore/`；更换开发团队时同步修改配置。实际录音、窗口采集和备忘录写入需要用户授予系统权限。自动自检不能代替真实设备的完整流程验证。

更多功能说明见 [应用 README](outputs/DuckIsland/README.md)。构建产物、开发过程截图、签名资料和账号审核资料均不纳入版本控制。

## CI 与 GitHub Release

GitHub Actions 在 PR、`main` 和 `ci/**` 分支 push 时验证；Actions 页面的 **macOS CI and Release → Run workflow** 只验证和生成临时下载产物，即使选择 tag 也不会发布 Release。

- 使用公开仓库的 `macos-15` Apple Silicon runner，并检查实际 `arm64` 架构；最低系统版本为 macOS 15。记录 runner 自带 Xcode/Swift/SDK 版本，不依赖本机 Xcode 路径。
- 普通发行使用 `swiftc -O` 编译；App Store 保留 `APP_STORE` 条件，通过 Release Xcode scheme 编译 app 与内嵌 NotesHelper，两者都不使用证书签名。无第三方包依赖，因此不配置依赖缓存。
- 离线测试覆盖双版本历史记录/AI 禁用、保存失败及进程超时、合成 PCM 与注入识别器的队列/收尾行为。测试不运行真实录音、屏幕采集、Notes、AI 或应用 `--self-test`。AppKit 窗口、剪贴板、离屏 UI 渲染和 TCC/真实 GUI 验收不在 headless CI 范围内；现有专用测试需在交互设备另行运行。

发布前确保提交已进入 `origin/main` 且 CI 成功，然后选择一个**未使用过**的版本：

```sh
git fetch origin
git tag -a v1.2.3 origin/main -m "Duck Island 1.2.3"
git push origin refs/tags/v1.2.3
```

支持 `vX.Y.Z` 或 `vX.Y.Z-rc.1` / `vX.Y.Z-beta.2` 等预发布格式；数字不得含前导零，预发布标识使用 ASCII 字母、数字、连字符和点，不支持 `+build`。非法 tag 会失败，不发布。预发布自动标记为 prerelease。tag 对应提交必须属于远端 main 的历史，移动过的 tag 和已有 Release（含草稿）会被拒绝。不要移动或重用发布 tag。

tag push 将重新运行全部 CI 门槛；成功后才发布 `Duck-Island-vX.Y.Z-macos-arm64.zip`、`SHA256SUMS` 和自动生成的 Release notes。ZIP 顶层为 `Duck Island.app`，只含直接发行版，不含 App Store 版。下载后解压并移入 Applications；在 ZIP 所在目录运行 `shasum -a 256 -c SHA256SUMS` 校验。`CFBundleShortVersionString`/`CFBundleVersion` 使用数字 `X.Y.Z`，完整 tag、commit SHA 和 Xcode 版本另存于 app 的 `Contents/Resources/build-info.json`，plist 也保存 tag 与 commit。常规 CI 产物使用 `v0.0.0-dev`，只在 Actions 保留 7 天，不是正式版本。

**签名状态：当前发布仅 ad-hoc 签名，没有 Developer ID，也没有 Apple 公证。** macOS Gatekeeper 可能阻止打开；详见 [Apple 安全打开应用说明](https://support.apple.com/en-us/102445)。ad-hoc 签名不提供可信开发者身份，更新可能需要重新授予隐私权限。流程不会关闭 Gatekeeper、更改系统信任、导出本机签名材料或访问用户钥匙串；现有本地 `build.sh` 权限稳定策略保持不变。

当前无需 Apple 账号或仓库 secret。初始化时仓库可见 secrets/variables 均为空；此流程不实现 Developer ID/公证切换，添加证书 secret 本身不会改变签名方式。如以后需要公证，应单独配置审核过的临时钥匙串与公证流程，不上传本地开发身份。仓库设置入口为 **Settings → Actions → General**（启用 Actions）及 **Secrets and variables → Actions**（未来配置）；`GITHUB_TOKEN` 自动提供，仅 release job 请求 `contents: write`，其他 job 为只读，PR 不使用 secrets 或 `pull_request_target`。

失败时查看 Actions 中失败步骤；测试/编译/校验失败不会发布。修复源码后使用新版本 tag。网络或上传失败可能留下草稿：维护者需先核查草稿及 commit，手动删除未发布草稿后才能重跑该次执行；脚本不会覆盖或自动删除已有内容。已发布版本必须用新 tag 修正。同 ref 的执行串行且不取消正在发布的任务；上传完成后才将草稿公开，避免发布半套产物。本次配置验证不创建正式 tag 或 Release。

维护依据（2026-11-05 核对）：[GitHub runner 规格](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[发布 API 权限](https://docs.github.com/en/rest/releases/releases#create-a-release)、[gh release create](https://cli.github.com/manual/gh_release_create)、[Apple 版本格式](https://developer.apple.com/help/glossary/version-number/)。仅使用维护中的官方 `actions/checkout`、`upload-artifact` 和 `download-artifact`，固定到完整 commit SHA（旁注版本），升级时核对官方发布记录；发布使用 runner 自带 GitHub CLI，不使用第三方发布 Action。
