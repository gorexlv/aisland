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
