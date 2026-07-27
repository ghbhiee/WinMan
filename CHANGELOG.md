# Changelog

## 1.1.0 - 2026-07-27

- 固定 Bundle ID，并使用稳定 Apple Development 签名避免每次编译改变权限身份。
- Universal Release 同时支持 Apple Silicon 和 Intel。
- Accessibility 操作失败时放行原生 Dock 点击。
- event tap 被系统关闭后自动恢复或重建。
- 修复多显示器、负坐标和四个 Dock 方向的预览定位。
- 保留无法取得 CGWindowID 的应用窗口。
- 串行执行 Finder Automation，避免快速点击时脚本竞争。
- 自动刷新 Dock 坐标，适配 Dock 位置、大小和自动隐藏变化。
- 登录时启动改为用户可控设置。
- 完善中文帮助、权限说明、作者信息和 GitHub 链接。
- 增加几何测试、发布脚本和项目文档。

## 1.0.0

- 初始版本。
- Dock 点击最小化与恢复。
- 多窗口悬停预览。
- Finder 最小化恢复支持。
