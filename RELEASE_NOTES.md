# WinMan 1.1.0

这是 WinMan 的第一个公开 GitHub Release。

主要更新：

- 点击 Dock 图标最小化或恢复最近活动窗口。
- Finder 支持 `Cmd-M`、黄色按钮和 Dock 点击后的可靠恢复。
- 多窗口悬停预览和更宽容的鼠标移动区域。
- 修复多显示器和不同 Dock 方向的定位。
- Accessibility 操作失败时自动回退到 macOS 原生 Dock 行为。
- 使用稳定签名身份，避免同一开发证书重编译后反复丢失权限。
- Universal Binary，同时支持 Apple Silicon 和 Intel。
- 新增登录项开关、完整中文帮助和 GitHub 项目信息。

安装说明：

1. 下载 ZIP 或 DMG。
2. 将 `WinMan.app` 移到 `/Applications`。
3. 首次运行时授予辅助功能和自动化权限。
4. 当前版本尚未经过 Developer ID 公证。如果 macOS 阻止首次打开，请在 Finder
   中右键 `WinMan.app` 并选择“打开”。

校验文件见 `SHA256SUMS.txt`。
