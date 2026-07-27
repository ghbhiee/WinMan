import Cocoa
import CoreGraphics
import SwiftUI
import ApplicationServices
import os

// Unified logging: visible in Console.app, debug-level lines are cheap in release.
enum WinManLog {
    static let app = Logger(subsystem: "com.winman.app", category: "app")
    static let dock = Logger(subsystem: "com.winman.app", category: "dock")
    static let tracker = Logger(subsystem: "com.winman.app", category: "tracker")
}

// MARK: - App entry point

@main
struct WinManApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("WinMan", systemImage: "rectangle.3.group") {
            Button(tr("设置", "Settings")) { appDelegate.openSettings() }
            Button(tr("帮助", "Help")) { appDelegate.openHelp() }
            Button(tr("设置向导", "Setup Guide")) { appDelegate.openOnboarding() }
            Divider()
            Button(tr("辅助功能设置", "Accessibility Preferences")) { appDelegate.openAccessibilityPreferences() }
            Button(tr("自动化设置", "Automation Preferences")) { appDelegate.openAutomationPreferences() }
            Divider()
            Button(tr("退出", "Quit")) { appDelegate.quit() }
        }
    }
}

private enum WinManIcon {
    static func appIcon() -> NSImage? {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else {
            return nil
        }
        return NSImage(contentsOf: url)
    }

}

// MARK: - AppDelegate

class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var eventTap: CFMachPort?
    var eventTapSource: CFRunLoopSource?
    var mainWindow: NSWindow?
    var helpWindow: NSWindow?
    var onboardingWindow: NSWindow?

    let dockMonitor = DockMonitor()
    let windowTracker = WindowTracker()
    var previewPanel: PreviewPanel?
    private var userRequestedQuit = false
    private var eventTapRetryWorkItem: DispatchWorkItem?
    private let finderAutomationQueue = DispatchQueue(
        label: "com.winman.finder-automation",
        qos: .userInitiated
    )
    private let previewBuildQueue = DispatchQueue(
        label: "com.winman.preview-thumbnails",
        qos: .userInitiated
    )
    private let githubURL = URL(string: "https://github.com/ghbhiee/WinMan")!

    // Settings
    var isToggleEnabled: Bool = {
        UserDefaults.standard.object(forKey: "ToggleEnabled") == nil ? true
            : UserDefaults.standard.bool(forKey: "ToggleEnabled")
    }()
    var isPreviewEnabled: Bool = {
        UserDefaults.standard.object(forKey: "PreviewEnabled") == nil ? true
            : UserDefaults.standard.bool(forKey: "PreviewEnabled")
    }()
    var isSingleWindowPreviewEnabled: Bool =
        UserDefaults.standard.bool(forKey: "PreviewSingleWindow")
    var hoverDelay: Double = {
        let v = UserDefaults.standard.double(forKey: "HoverDelay")
        return v == 0 ? 1.0 : v
    }()

    // Hover state
    var hoverTimer: Timer?
    var hoveredDockItem: DockItem?
    var dismissPreviewTimer: Timer?

    // Suppress preview for a short period after a user click/right-click action.
    // Time-based avoids the "flag gets stuck" problem that a boolean exit-gate has.
    var suppressPreviewUntil: Date = .distantPast

    // App name overrides: Dock display name → NSRunningApplication.localizedName
    let appNameOverrides: [String: String] = [
        "Visual Studio Code": "Code",
        "Rosetta Stone Learn Languages": "Rosetta Stone",
        // Chinese macOS localized names for system apps
        "访达": "Finder",
        "系统偏好设置": "System Preferences",
        "系统设置": "System Settings",
    ]


    // Apps with dock icons that don't map to a toggleable window.
    // Non-application dock items (folders, Trash, separators) are already
    // filtered by subrole; these cover apps that have no toggleable window.
    let skippedApps: Set<String> = ["Launchpad", "启动台", "Trash", "Downloads"]
    let skippedBundleIDs: Set<String> = ["com.apple.launchpad.launcher"]

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)
        if let appIcon = WinManIcon.appIcon() {
            NSApplication.shared.applicationIconImage = appIcon
        }
        ProcessInfo.processInfo.disableAutomaticTermination("WinMan must stay resident to manage Dock clicks.")

        // Cap synchronous AX calls process-wide. Without this, one hung app can
        // stall the event tap callback long enough to freeze mouse input
        // system-wide; a timed-out operation instead falls back to the native
        // Dock click.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.25)

        // First launch, or a required permission is missing: show the guided
        // permission wizard instead of a bare alert.
        if !UserDefaults.standard.bool(forKey: "OnboardingShown") || !AXIsProcessTrusted() {
            openOnboarding()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsChanged),
            name: .winManSettingsChanged,
            object: nil
        )

        dockMonitor.startObserving()
        windowTracker.startTracking()

        setupEventTap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        eventTapRetryWorkItem?.cancel()
        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
        }
        NotificationCenter.default.removeObserver(self)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if let event = NSAppleEventManager.shared().currentAppleEvent,
           event.eventClass == kCoreEventClass,
           event.eventID == kAEQuitApplication {
            return .terminateNow
        }
        return userRequestedQuit
            ? NSApplication.TerminateReply.terminateNow
            : NSApplication.TerminateReply.terminateCancel
    }

    func quit() {
        userRequestedQuit = true
        NSApplication.shared.terminate(nil)
    }

    @objc func settingsChanged() {
        isToggleEnabled = UserDefaults.standard.bool(forKey: "ToggleEnabled")
        isPreviewEnabled = UserDefaults.standard.bool(forKey: "PreviewEnabled")
        isSingleWindowPreviewEnabled = UserDefaults.standard.bool(forKey: "PreviewSingleWindow")
        let v = UserDefaults.standard.double(forKey: "HoverDelay")
        hoverDelay = v == 0 ? 1.0 : v
    }

    // MARK: - Settings window

    func openSettings() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let hosting = NSHostingController(rootView: ContentView())
            let window = NSWindow(contentViewController: hosting)
            window.title = tr("WinMan 设置", "WinMan Settings")
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            window.level = .floating
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            self.mainWindow = window
        }
    }

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
        • 应用有多个窗口时，将鼠标停留在 Dock 图标上可显示窗口预览。
        • 点击某个预览可直接恢复并激活对应窗口。
        • 悬停缩略图时右上角出现 ✕，点击可直接关闭该窗口（与 Windows 任务栏一致）。
        • 全屏窗口保留 macOS 原生 Dock 行为，不会被 WinMan 强制最小化。
        """, """
        • Click the frontmost app's Dock icon: minimize its most recent window.
        • Click the icon again: restore the last active or minimized window.
        • Hover over an app with multiple windows to show clickable previews.
        • Click a preview to restore and activate that window.
        • Hover a thumbnail and click the ✕ in its corner to close that window,
          just like the Windows taskbar.
        • Full-screen windows keep native macOS Dock behavior.
        """), font: .systemFont(ofSize: 13))

        section("Finder")
        append(tr("""
        Finder 使用独立的 System Events 处理逻辑。无论通过 Cmd-M、黄色最小化按钮，
        还是 WinMan 的 Dock 点击最小化，都可以再次点击 Finder 图标恢复窗口。
        """, """
        Finder uses dedicated System Events handling. Windows minimized with
        Cmd-M, the yellow button, or a WinMan Dock click can all be restored by
        clicking the Finder icon again.
        """), font: .systemFont(ofSize: 13))

        section(tr("权限", "Permissions"))
        append(tr("""
        • 辅助功能：必须，用于读取 Dock 图标位置以及读取和改变窗口状态。
        • 自动化：仅 Finder 窗口管理需要（System Events）；其余功能不再依赖。
        • 屏幕录制：可选，仅用于显示实时窗口缩略图；拒绝后仍可使用窗口切换。

        如果点击没有反应，请先通过菜单栏的「设置向导」确认 WinMan 已授权。
        更换签名身份时可能需要最后重新授权一次；以后使用相同签名编译不会反复失效。
        """, """
        • Accessibility: required — reads Dock icon positions and manages windows.
        • Automation: needed only for Finder window management (System Events).
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
        append(tr("作者：Guohongbo\n联系：ghbhiee@gmail.com\nGitHub：",
                  "Author: Guohongbo\nContact: ghbhiee@gmail.com\nGitHub: "),
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

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === mainWindow {
            mainWindow = nil
        } else if window === helpWindow {
            helpWindow = nil
        } else if window === onboardingWindow {
            onboardingWindow = nil
        }
    }

    // MARK: - Onboarding wizard

    func openOnboarding() {
        UserDefaults.standard.set(true, forKey: "OnboardingShown")
        if let window = onboardingWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let view = OnboardingView(
            openSecurityPane: { [weak self] pane in self?.openSecurityPane(pane) },
            onDone: { [weak self] in self?.onboardingWindow?.close() }
        )
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = tr("WinMan 设置向导", "WinMan Setup Guide")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        window.level = .floating
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow = window
    }

    // MARK: - Event tap

    func setupEventTap() {
        eventTapRetryWorkItem?.cancel()
        eventTapRetryWorkItem = nil

        if let source = eventTapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            eventTapSource = nil
        }
        if let tap = eventTap {
            CFMachPortInvalidate(tap)
            eventTap = nil
        }

        guard AXIsProcessTrusted() else {
            scheduleEventTapRetry()
            return
        }

        let eventMask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue) |
            (1 << CGEventType.mouseMoved.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .tailAppendEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: { proxy, type, event, refcon -> Unmanaged<CGEvent>? in
                let delegate = Unmanaged<AppDelegate>.fromOpaque(refcon!).takeUnretainedValue()
                return AppDelegate.eventTapCallback(proxy: proxy, type: type, event: event, delegate: delegate)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            WinManLog.app.error("Failed to create event tap")
            scheduleEventTapRetry()
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        self.eventTap = tap
        self.eventTapSource = source
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func scheduleEventTapRetry() {
        eventTapRetryWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.setupEventTap()
        }
        eventTapRetryWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: workItem)
    }

    static func eventTapCallback(
        proxy: CGEventTapProxy,
        type: CGEventType,
        event: CGEvent?,
        delegate: AppDelegate
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = delegate.eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
                if !CGEvent.tapIsEnabled(tap: tap) {
                    DispatchQueue.main.async { delegate.setupEventTap() }
                }
            }
            return nil
        }

        guard let event = event else { return nil }
        let location = event.location

        switch type {
        case .mouseMoved:
            if delegate.isPreviewEnabled {
                AppDelegate.handleMouseMoved(location: location, delegate: delegate)
            }
        case .rightMouseDown:
            AppDelegate.handleRightClick(location: location, delegate: delegate)
        case .leftMouseDown:
            if delegate.isToggleEnabled {
                let suppress = AppDelegate.handleClick(location: location, delegate: delegate)
                if suppress { return nil }
            }
            delegate.rememberFrontmostWindowAfterUserClick()
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Click handling

    static func handleClick(location: CGPoint, delegate: AppDelegate) -> Bool {
        for dockItem in delegate.dockMonitor.items {
            guard dockItem.rect.contains(location) else { continue }
            // Folders, the Trash, and separators keep native Dock behavior.
            guard dockItem.isApplication else { return false }
            guard !delegate.skippedApps.contains(dockItem.name) else { return false }
            if let bundleID = dockItem.bundleID,
               delegate.skippedBundleIDs.contains(bundleID) { return false }
            guard AXIsProcessTrusted() else { return false }

            let apps = NSWorkspace.shared.runningApplications
            guard let app = apps.first(where: { delegate.matches(app: $0, dockItem: dockItem) }) else {
                WinManLog.app.debug("No running app for: \(dockItem.name, privacy: .public)")
                return false
            }

            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier
            if app.bundleIdentifier == "com.apple.finder" {
                guard delegate.dockMonitor.isAvailable else { return false }
                delegate.handleFinderDockClick(isFrontmost: isFrontmost, isHidden: app.isHidden)
                delegate.suppressPreviewUntil = Date().addingTimeInterval(1.5)
                delegate.hoverTimer?.invalidate()
                delegate.hoverTimer = nil
                delegate.dismissPreviewTimer?.invalidate()
                delegate.dismissPreviewTimer = nil
                delegate.previewPanel?.dismiss()
                return true
            }

            let orderedWindows = delegate.windowTracker.windowsInInteractionOrder(for: app)
            let freshWindow = isFrontmost && !app.isHidden
                ? delegate.windowTracker.currentFocusedWindow(for: app)
                : nil
            let window = freshWindow ?? orderedWindows.first

            if let w = window, delegate.windowTracker.isFullscreen(w) {
                return false  // pass through for fullscreen
            }

            let windowIsMinimized = window.map { delegate.windowTracker.isMinimized($0) } ?? false

            WinManLog.app.debug("\(app.localizedName ?? dockItem.name, privacy: .public) frontmost=\(isFrontmost) minimized=\(windowIsMinimized)")

            let handled: Bool
            if isFrontmost && !app.isHidden && !windowIsMinimized {
                guard let window else { return false }
                delegate.windowTracker.setLastActiveWindow(window, for: app)
                handled = delegate.windowTracker.minimizeWindow(window)
            } else {
                guard let window else {
                    // Let the native Dock click reopen apps that currently have no window.
                    return false
                }
                handled = delegate.windowTracker.restoreAndRaise(window, app: app)
                if handled {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        if let fresh = delegate.windowTracker.currentFocusedWindow(for: app) {
                            delegate.windowTracker.setLastActiveWindow(fresh, for: app)
                        }
                    }
                }
            }

            guard handled else {
                WinManLog.app.debug("Window operation failed; passing the Dock click through")
                return false
            }

            // Suppress hover preview for 1.5s after a real action — time-based so it never gets stuck
            delegate.suppressPreviewUntil = Date().addingTimeInterval(1.5)
            delegate.hoverTimer?.invalidate()
            delegate.hoverTimer = nil
            delegate.dismissPreviewTimer?.invalidate()
            delegate.dismissPreviewTimer = nil
            delegate.previewPanel?.dismiss()
            return true
        }
        return false
    }

    func rememberFrontmostWindowAfterUserClick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self,
                  let app = NSWorkspace.shared.frontmostApplication,
                  let window = self.windowTracker.currentFocusedWindow(for: app) else { return }
            self.windowTracker.setLastActiveWindow(window, for: app)
        }
    }

    /// Finder needs System Events; generic AX elements can look stale after Cmd-M.
    func handleFinderDockClick(isFrontmost: Bool, isHidden: Bool) {
        finderAutomationQueue.async {
            let script = """
            set shouldActivateFinder to true
            set shouldCreateNewWindow to false

            tell application "System Events"
                tell process "Finder"
                    set visibleWindows to every window whose value of attribute "AXMinimized" is false
                    set minimizedWindows to every window whose value of attribute "AXMinimized" is true

                    if \(isFrontmost && !isHidden) and (count of visibleWindows) > 0 then
                        set value of attribute "AXMinimized" of item 1 of visibleWindows to true
                        set shouldActivateFinder to false
                    else if (count of minimizedWindows) > 0 then
                        set targetWindow to item 1 of minimizedWindows
                        set value of attribute "AXMinimized" of targetWindow to false
                        perform action "AXRaise" of targetWindow
                    else if (count of visibleWindows) > 0 then
                        perform action "AXRaise" of item 1 of visibleWindows
                    else
                        set shouldCreateNewWindow to true
                    end if
                end tell
            end tell

            if shouldCreateNewWindow then tell application "Finder" to make new Finder window
            if shouldActivateFinder then tell application "Finder" to activate
            """
            var err: NSDictionary?
            NSAppleScript(source: script)?.executeAndReturnError(&err)
            if let err = err {
                WinManLog.app.error("Finder click error: \(err, privacy: .public)")
            }
        }
    }

    // MARK: - Right-click handling

    static func handleRightClick(location: CGPoint, delegate: AppDelegate) {
        guard delegate.dockMonitor.items.contains(where: { $0.rect.contains(location) }) else { return }
        delegate.hoverTimer?.invalidate()
        delegate.hoverTimer = nil
        delegate.dismissPreviewTimer?.invalidate()
        delegate.dismissPreviewTimer = nil
        delegate.hoveredDockItem = nil
        delegate.previewPanel?.dismiss()
        // Suppress for 2s so preview doesn't appear over the context menu
        delegate.suppressPreviewUntil = Date().addingTimeInterval(2.0)
    }

    // MARK: - Hover preview handling

    static func handleMouseMoved(location: CGPoint, delegate: AppDelegate) {
        delegate.dockMonitor.refreshIfNeeded(near: location)

        // After a click or right-click action, hover preview is suppressed for a short time.
        // Time-based suppression never gets permanently stuck unlike an exit-gate boolean.
        if Date() < delegate.suppressPreviewUntil {
            // Cancel any hover timer that might be running, but don't start a new one
            delegate.hoverTimer?.invalidate()
            delegate.hoverTimer = nil
            return
        }

        let isOverPanel = delegate.isLocationOverPanel(location)

        if let dockItem = delegate.dockMonitor.items.first(where: { $0.rect.contains(location) }) {
            delegate.dismissPreviewTimer?.invalidate()
            delegate.dismissPreviewTimer = nil

            if delegate.hoveredDockItem?.identity != dockItem.identity {
                // Moved to a different dock item — dismiss previous panel and restart timer
                delegate.hoverTimer?.invalidate()
                delegate.previewPanel?.dismiss()
                delegate.hoveredDockItem = dockItem

                delegate.hoverTimer = Timer.scheduledTimer(
                    withTimeInterval: delegate.hoverDelay,
                    repeats: false
                ) { [weak delegate] _ in
                    guard let delegate = delegate else { return }
                    DispatchQueue.main.async { delegate.showPreview(for: dockItem) }
                }
            }
        } else if isOverPanel {
            // Over the panel — cancel any pending dismiss
            delegate.dismissPreviewTimer?.invalidate()
            delegate.dismissPreviewTimer = nil
        } else {
            // Left both dock and panel
            delegate.hoverTimer?.invalidate()
            delegate.hoverTimer = nil
            delegate.hoveredDockItem = nil

            if delegate.previewPanel?.isVisible == true, delegate.dismissPreviewTimer == nil {
                delegate.dismissPreviewTimer = Timer.scheduledTimer(
                    withTimeInterval: 0.4,
                    repeats: false
                ) { [weak delegate] _ in
                    DispatchQueue.main.async { delegate?.previewPanel?.dismiss() }
                    delegate?.dismissPreviewTimer = nil
                }
            }
        }
    }

    func isLocationOverPanel(_ location: CGPoint) -> Bool {
        guard let panel = previewPanel,
              panel.isVisible,
              let dockItem = hoveredDockItem,
              let primaryScreenFrame = NSScreen.screens.first?.frame else {
            return false
        }

        let appKitLocation = ScreenGeometry.appKitPoint(
            fromQuartz: location,
            primaryScreenFrame: primaryScreenFrame
        )
        let appKitDockRect = ScreenGeometry.appKitRect(
            fromQuartz: dockItem.rect,
            primaryScreenFrame: primaryScreenFrame
        )
        return ScreenGeometry.containsPreviewPath(
            appKitLocation,
            dockRect: appKitDockRect,
            panelRect: panel.frame
        )
    }

    func showPreview(for dockItem: DockItem) {
        guard isPreviewEnabled else { return }

        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { self.matches(app: $0, dockItem: dockItem) }) else { return }

        // Put the tracked active window first, then fall back to system Z-order.
        let axWindows = windowTracker.windowsInInteractionOrder(for: app)
        guard axWindows.count >= minimumPreviewWindowCount else { return }

        // Collect metadata on the main thread; window imaging happens off it so
        // the event tap callback is never blocked by slow captures.
        var items: [WindowPreviewItem] = []
        for axWindow in axWindows {
            let title = windowTracker.windowTitle(axWindow) ?? ""
            let wid = windowTracker.windowID(axWindow)
            let minimized = windowTracker.isMinimized(axWindow)

            let itemID: String
            if let wid {
                itemID = "cg:\(wid)"
            } else {
                let pointer = Unmanaged.passUnretained(axWindow).toOpaque()
                itemID = "ax:\(UInt(bitPattern: pointer))"
            }
            items.append(WindowPreviewItem(
                id: itemID, element: axWindow, title: title,
                thumbnail: nil, isMinimized: minimized, windowID: wid
            ))
        }

        guard !items.isEmpty else { return }

        let canCapture = CGPreflightScreenCaptureAccess()
        previewBuildQueue.async { [weak self] in
            let readyItems = items.map { item -> WindowPreviewItem in
                guard canCapture, !item.isMinimized, let wid = item.windowID else { return item }
                var updated = item
                updated.thumbnail = captureWindowThumbnail(
                    windowID: wid,
                    targetSize: CGSize(width: 156, height: 116)
                )
                return updated
            }

            DispatchQueue.main.async {
                guard let self else { return }
                // The pointer may have moved on while thumbnails were captured.
                guard self.isPreviewEnabled,
                      self.hoveredDockItem?.identity == dockItem.identity,
                      Date() >= self.suppressPreviewUntil else { return }

                if self.previewPanel == nil { self.previewPanel = PreviewPanel() }

                self.previewPanel?.show(
                    for: app, windows: readyItems, nearDockRect: dockItem.rect,
                    onSelect: { [weak self] element, app in
                        self?.previewPanel?.dismiss()
                        self?.windowTracker.setLastActiveWindow(element, for: app)
                        if self?.windowTracker.restoreAndRaise(element, app: app) == false {
                            NSSound.beep()
                        }
                    },
                    onCloseWindow: { [weak self] item in
                        self?.closeWindowFromPreview(item, app: app, dockItem: dockItem)
                    }
                )
            }
        }
    }

    private var minimumPreviewWindowCount: Int {
        isSingleWindowPreviewEnabled ? 1 : 2
    }

    /// Close a window from its preview thumbnail, then refresh the panel with
    /// the surviving windows (or dismiss it when too few remain).
    private func closeWindowFromPreview(_ item: WindowPreviewItem, app: NSRunningApplication, dockItem: DockItem) {
        guard windowTracker.closeWindow(item.element) else {
            NSSound.beep()
            return
        }
        // Give the app a moment to tear the window down before re-enumerating.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            let remaining = self.windowTracker.windowsInInteractionOrder(for: app)
            if remaining.count >= self.minimumPreviewWindowCount {
                self.showPreview(for: dockItem)
            } else {
                self.previewPanel?.dismiss()
            }
        }
    }

    // MARK: - App matching

    /// Exact match via the dock item's AXURL-derived bundle identity; the
    /// legacy display-name heuristics only run when the Dock exposes no URL.
    func matches(app: NSRunningApplication, dockItem: DockItem) -> Bool {
        if let bundleID = dockItem.bundleID {
            return app.bundleIdentifier == bundleID
        }
        if let itemURL = dockItem.bundleURL, let appURL = app.bundleURL {
            return itemURL.standardizedFileURL.path == appURL.standardizedFileURL.path
        }
        return matches(app: app, dockName: dockItem.name)
    }

    func matches(app: NSRunningApplication, dockName: String) -> Bool {
        if app.localizedName == dockName { return true }
        // Override dict (handles localized dock names, e.g. "访达" → Finder)
        if let overridden = appNameOverrides[dockName], app.localizedName == overridden { return true }
        // Bundle URL filename match (e.g. "Code.app" → "Code")
        if let name = app.bundleURL?.deletingPathExtension().lastPathComponent,
           name == dockName { return true }
        // Finder: may appear as "Finder" or "访达" depending on macOS locale
        if app.bundleIdentifier == "com.apple.finder",
           dockName == "Finder" || dockName == "访达" { return true }
        return false
    }

    // MARK: - Permissions

    func openSecurityPane(_ pane: String) {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?\(pane)"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openAccessibilityPreferences() {
        openSecurityPane("Privacy_Accessibility")
    }

    func openAutomationPreferences() {
        openSecurityPane("Privacy_Automation")
    }
}
