# Changelog

## Unreleased

- 新增首次启动「设置向导」：三项权限（辅助功能/自动化/屏幕录制）实时状态、一键授权/申请，自动化权限用 AEDeterminePermissionToAutomateTarget 被动探测不误触弹窗；菜单栏可随时重新打开，取代原来的单个警告弹窗。
- 界面全面中英双语：菜单栏、设置、帮助、向导按系统语言自动切换（zh-* 显示中文，其余英文）。
- 最近活动窗口改为 AXObserver 事件驱动追踪：前台应用焦点/主窗口一变化即刻记录，修复用 Cmd-\`、Mission Control 等键盘途径切换窗口后点击 Dock 图标操作到错误窗口的问题；原有点击探测保留为兜底。
- Dock 读取从 System Events AppleScript 改为直接 Accessibility API：不再经过 Apple Events，读取 Dock 不再需要 Automation 权限（Automation 现仅 Finder 窗口管理需要）。
- 通过 Dock 项的 AXURL 解析 bundle ID 精确匹配运行中的应用，取代按本地化显示名猜测；对所有系统语言天然正确（如 访达/Finder、Visual Studio Code/Code），并兼容 Safari 等 Cryptex 路径应用。
- 按 subrole 过滤 Dock 项：文件夹、废纸篓、分隔符点击保持原生行为，不再依赖英文名单。
- 全局 AX 消息超时（0.25s）：目标应用无响应时不再拖慢 event tap，避免全系统鼠标输入卡顿，超时操作自动放行原生 Dock 点击。
- 预览缩略图截屏移至后台线程，悬停多窗口时主线程与鼠标事件不再被阻塞。
- 鼠标远离 Dock 时将 System Events 刷新间隔从 2 秒降频到 20 秒，显著减少 AppleScript 后台开销。
- Dock 读取脚本编译一次后复用，并改用串行队列执行。
- 消除窗口枚举中重复的 `_AXUIElementGetWindow` 进程间调用（原为 O(n²)）。
- 预览面板宽度按实际缩略图内容精确计算，去掉多余空白。
- 设置页新增屏幕录制权限状态与一键申请按钮；权限状态每 2 秒自动刷新。
- 热路径日志从 print 迁移到统一日志（os.Logger），Console.app 可按 com.winman.app 过滤。
- 新增 Dock 边缘判定、面板宽度与屏幕边缘约束的几何测试。

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
