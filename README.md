# WinMan

WinMan 是一个轻量级 macOS 菜单栏窗口管理工具，让 Dock 图标具有类似 Windows
任务栏的点击行为。

## 为什么做 WinMan

macOS 一直有一套与 Windows 很不一样的窗口管理方式。很难简单地说哪一种更合理：
macOS 更强调“应用”和“多文档”，Windows 则更倾向于让窗口本身成为直接操作对象。
但作为一个使用 Windows 多年、现在仍然需要每天同时使用两个平台的人，我经常无法
适应 macOS 的这套交互。

`Cmd-M` 只负责最小化一个窗口，`Cmd-H` 隐藏的是整个应用；Dock 中通常只有应用图标，
而不是每个窗口的入口。我理解这背后的多文档模型，但理解它并不意味着这种操作就能
满足我的实际需要。

我更喜欢一种“所见即所得”的方式：

- 点击 Dock 图标，显示窗口。
- 再次点击同一个图标，收起窗口。
- 同一个按钮可以连续点击，在显示和最小化之间切换。

这不只是 Windows 的习惯，也是很多互联网产品里常见的开关式交互。用户不需要把鼠标
移到窗口左上角，也不必打开右键菜单寻找窗口，就可以在原位置快速浏览、收起，再打开
窗口。WinMan 想解决的就是这件很小、但每天会重复很多次的事情。

多文档应用确实让问题更复杂。WinMan 目前通过悬停预览展示多个窗口，这是对 macOS
应用模型的一种折中，但效果还不能说完美：窗口被快速创建或关闭时，系统的
Accessibility 状态可能有短暂延迟，最近活动窗口的判断和预览顺序偶尔会不够理想。

项目早期还尝试过把同一个应用的多个文档分别显示成多个 Dock 图标，希望像 Windows
任务栏一样直接点击每个窗口。但这种方式与 macOS 的应用生命周期、焦点切换和 Dock
模型冲突较多，产生的问题比解决的问题更多，因此最终移除了。

WinMan 并不是要证明 Windows 比 macOS 更正确，也不是要把 macOS 完全改造成
Windows。它只是为同时使用两个平台、偏好直接窗口切换的人，补上一种可选且一致的
操作方式。

## 功能

- 点击前台应用的 Dock 图标，最小化最近活动窗口。
- 再次点击同一图标，恢复上次活动或最小化的窗口。
- 悬停在多窗口应用图标上，显示可点击的窗口预览。
- Finder 专用恢复逻辑，兼容 `Cmd-M`、黄色按钮和 Dock 点击最小化。
- 记住多窗口应用最近使用的窗口。
- 支持底部、顶部、左侧和右侧 Dock，以及多显示器坐标。
- 用户可配置悬停延迟、关闭预览和选择是否登录时启动。

## 系统要求

- macOS 13 Ventura 或更高版本。
- Apple Silicon 或 Intel Mac。

## 安装

从 [GitHub Releases](https://github.com/ghbhiee/WinMan/releases) 下载最新版，
将 `WinMan.app` 移到 `/Applications` 后打开。

当前公开构建使用 Apple Development 证书签名，但尚未使用 Developer ID 公证。
首次从 GitHub 下载后，如果 macOS 阻止打开，请在 Finder 中右键
`WinMan.app` 并选择“打开”。后续取得 Developer ID 证书后，发布脚本已经支持
notarization 和 stapling。

## 权限

WinMan 使用以下 macOS 权限：

- 辅助功能：管理、最小化和恢复窗口，属于必需权限。
- 自动化：通过 System Events 读取 Dock 图标位置并管理 Finder，属于必需权限。
- 屏幕录制：只用于窗口预览缩略图，可以拒绝。

应用的 Bundle ID 固定为 `com.winman.app`。开发者本机使用同一 Apple 签名证书
编译后，权限身份保持稳定，不会再因为每次 ad-hoc 签名产生新的 CDHash 而反复失效。
从旧的 ad-hoc 构建切换到稳定签名构建时，可能需要最后重新授权一次。

## 构建

```bash
git clone https://github.com/ghbhiee/WinMan.git
cd WinMan
./scripts/test.sh
xcodebuild -project WinMan.xcodeproj -scheme WinMan -configuration Debug build
```

工程默认使用作者的 Apple Development Team。其他开发者可以在 Xcode Signing
设置中选择自己的 Team，或在命令行覆盖 `DEVELOPMENT_TEAM`。

生成 Universal Release：

```bash
./scripts/build-release.sh
```

使用 Developer ID 和公证：

```bash
WINMAN_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
WINMAN_TEAM_ID="TEAMID" \
WINMAN_NOTARY_PROFILE="notary-profile" \
./scripts/build-release.sh
```

## 隐私

WinMan 不上传窗口标题、截图或使用数据，不包含分析服务。窗口缩略图只在本机内存中
生成。应用中的网络链接仅用于打开 GitHub 项目页面。

## 已知限制

- 窗口与缩略图的关联使用私有 AX 符号 `_AXUIElementGetWindow`，因此当前不以
  Mac App Store 为发布目标。
- 某些应用不提供标准 Accessibility 窗口属性；操作失败时 WinMan 会放行原生
  Dock 点击。
- 未公证构建的首次启动仍受 Gatekeeper 限制。

## 作者

作者：Guohongbo

联系邮箱：ghbhiee@gmail.com

GitHub：[ghbhiee/WinMan](https://github.com/ghbhiee/WinMan)

## License

Copyright (c) 2026 Guohongbo. All rights reserved. 详见 [LICENSE](LICENSE)。
