import Cocoa

// The scrollable bilingual help window.
extension AppDelegate {

    func openHelp() {
        if let window = helpWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let window = makeHelpWindow()
            window.center()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.helpWindow = window
        }
    }

    private func makeHelpWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 640, height: 620),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = tr("WinMan 使用帮助", "WinMan Help")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.level = .floating
        window.minSize = NSSize(width: 520, height: 440)

        let textView = NSTextView(frame: window.contentLayoutRect)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 24, height: 22)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]
        textView.textStorage?.setAttributedString(makeHelpText())

        let scrollView = NSScrollView(frame: window.contentLayoutRect)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.documentView = textView
        window.contentView = scrollView

        return window
    }

    private func makeHelpText() -> NSAttributedString {
        let text = NSMutableAttributedString()
        let paragraph = NSMutableParagraphStyle()
        paragraph.paragraphSpacing = 7
        paragraph.lineSpacing = 2

        func append(_ value: String, font: NSFont, color: NSColor = .labelColor) {
            text.append(NSAttributedString(
                string: value,
                attributes: [
                    .font: font,
                    .foregroundColor: color,
                    .paragraphStyle: paragraph,
                ]
            ))
        }

        func section(_ title: String) {
            append("\n\(title)\n", font: .boldSystemFont(ofSize: 15))
        }

        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "Unknown"

        append(tr("WinMan 使用帮助\n", "WinMan Help\n"), font: .boldSystemFont(ofSize: 24))
        append(tr("版本 \(version) · 让 macOS Dock 图标像 Windows 任务栏一样切换窗口。\n",
                  "Version \(version) · Make macOS Dock icons toggle windows like the Windows taskbar.\n"),
               font: .systemFont(ofSize: 13),
               color: .secondaryLabelColor)

        section(tr("基本操作", "Basics"))
        append(tr("""
        • 点击当前前台应用的 Dock 图标：最小化最近使用的窗口。
        • 再次点击该图标：恢复上次活动或最小化的窗口。
        • ⌥Tab 打开全局窗口切换器（含最小化窗口）：按住 ⌥ 连续 Tab 循环，
          ⇧⌥Tab 反向，松开 ⌥ 切换到所选窗口，Esc 取消。
        • 全屏窗口保留 macOS 原生 Dock 行为，不会被 WinMan 强制最小化。
        """, """
        • Click the frontmost app's Dock icon: minimize its most recent window.
        • Click the icon again: restore the last active or minimized window.
        • ⌥Tab opens a global window switcher (including minimized windows):
          keep holding ⌥ and press Tab to cycle, ⇧⌥Tab to go backwards,
          release ⌥ to switch, Esc to cancel.
        • Full-screen windows keep native macOS Dock behavior.
        """), font: .systemFont(ofSize: 13))

        section(tr("单视图模式（白名单应用）", "Single-view mode (allowlisted apps)"))
        append(tr("""
        对白名单里的应用（默认 Finder 和 Chrome，可在设置中增删），WinMan 把每个窗口
        当作独立的「视图」来管理，像 Windows 任务栏一样：
        • 鼠标停在 Dock 图标上即显示各窗口的预览，移到预览再点击即可打开该窗口；
          预览已显示时滑到相邻图标会立即切换。点击卡片才会把窗口拉到前台。
        • 打开或恢复某个窗口时，只有这个窗口会到前面，同应用的其他窗口留在原处，
          不会被一起带出来。
        • Dock 图标始终操作 WinMan 最近处理的那个窗口：最小化 A 之后再点，恢复的
          一定是 A，不会变成同应用的其他窗口。
        • 悬停缩略图时右上角出现「最小化/恢复」和「关闭」按钮；按 Esc 关闭预览。
        • 蓝色标题 = 最近激活的窗口，即 Dock 点击的操作目标。
        • 接了多台显示器时，缩略图左上角标注窗口所在的屏幕。
        白名单之外的应用完全保持 macOS 原生行为，鼠标悬停不会有任何干扰。
        """, """
        For allowlisted apps (Finder and Chrome by default; edit the list in
        Settings) WinMan treats every window as its own "view", like the
        Windows taskbar:
        • Hovering the Dock icon shows a preview of each window; move onto a
          preview and click to open that window. With a preview already up,
          sliding to a neighboring icon switches instantly.
        • Opening or restoring a window brings only that window forward — the
          app's other windows stay where they are.
        • The Dock icon always acts on the window WinMan handled last: minimize
          A, click again, and A comes back — never some other window.
        • Hovering a card reveals minimize/restore and close buttons; Esc
          closes the preview row.
        • A blue title marks the last-active window — what a Dock click acts on.
        • With several displays attached, each card notes which screen its
          window is on.
        Apps outside the allowlist keep native macOS behavior; hovering their
        icons does nothing.
        """), font: .systemFont(ofSize: 13))

        section(tr("权限", "Permissions"))
        append(tr("""
        • 辅助功能：必须，用于读取 Dock 图标位置以及读取和改变窗口状态。
        • 屏幕录制：可选，仅用于显示实时窗口缩略图；拒绝后仍可使用窗口切换。

        如果点击没有反应，请先通过菜单栏的「设置向导」确认 WinMan 已授权。
        更换签名身份时可能需要最后重新授权一次；以后使用相同签名编译不会反复失效。
        """, """
        • Accessibility: required — reads Dock icon positions and manages windows.
        • Screen Recording: optional — live window thumbnails only.

        If clicks do nothing, open the Setup Guide from the menu bar and confirm
        WinMan is authorized. A signing identity change may require one final
        re-authorization; the same identity will not keep invalidating grants.
        """), font: .systemFont(ofSize: 13))

        section(tr("设置", "Settings"))
        append(tr("""
        可单独关闭 Dock 点击切换或悬停预览，也可以调整悬停延迟，
        还可以选择只有一个窗口时也显示预览。
        “登录时自动启动”由用户自行开启，WinMan 不再在每次启动时强制注册登录项。
        """, """
        Dock click toggling and hover previews can be disabled independently,
        the hover delay is adjustable, and previews can optionally appear even
        for a single window. "Launch at login" is entirely user-controlled.
        """), font: .systemFont(ofSize: 13))

        section(tr("故障排查", "Troubleshooting"))
        append(tr("""
        • 权限正常但功能失效：退出并重新打开 WinMan。
        • 只有缩略图不可见：检查屏幕录制权限。
        • Dock 移动、缩放或自动隐藏后：移动鼠标几秒，WinMan 会自动刷新图标位置。
        • 从 GitHub 首次下载的未公证版本：可在 Finder 中右键应用并选择“打开”。
        """, """
        • Permissions look fine but nothing happens: quit and reopen WinMan.
        • Only thumbnails are missing: check Screen Recording permission.
        • After moving or resizing the Dock: move the mouse for a few seconds
          and WinMan refreshes icon positions automatically.
        • First launch of a non-notarized GitHub download: right-click the app
          in Finder and choose Open.
        """), font: .systemFont(ofSize: 13))

        section(tr("作者与项目", "Author & Project"))
        append(tr("作者：Guohongbo\n联系：guohongbo@outlook.com\nGitHub：",
                  "Author: Guohongbo\nContact: guohongbo@outlook.com\nGitHub: "),
               font: .systemFont(ofSize: 13))
        text.append(NSAttributedString(
            string: githubURL.absoluteString,
            attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .link: githubURL,
                .foregroundColor: NSColor.linkColor,
                .paragraphStyle: paragraph,
            ]
        ))
        append("\n", font: .systemFont(ofSize: 13))
        return text
    }
}
