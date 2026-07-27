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
            Button("Settings") { appDelegate.openSettings() }
            Button("Help") { appDelegate.openHelp() }
            Divider()
            Button("Accessibility Preferences") { appDelegate.openAccessibilityPreferences() }
            Button("Automation Preferences") { appDelegate.openAutomationPreferences() }
            Divider()
            Button("Quit") { appDelegate.quit() }
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


    // Apps with dock icons that don't map to a toggleable window
    let skippedApps: Set<String> = ["Launchpad", "Trash", "Downloads"]

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

        if !AXIsProcessTrusted() {
            promptForAccessibilityPermission()
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
            window.title = "WinMan Settings"
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
        window.title = "WinMan 使用帮助"
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

        append("WinMan 使用帮助\n", font: .boldSystemFont(ofSize: 24))
        append("版本 \(version) · 让 macOS Dock 图标像 Windows 任务栏一样切换窗口。\n",
               font: .systemFont(ofSize: 13),
               color: .secondaryLabelColor)

        section("基本操作")
        append("""
        • 点击当前前台应用的 Dock 图标：最小化最近使用的窗口。
        • 再次点击该图标：恢复上次活动或最小化的窗口。
        • 应用有多个窗口时，将鼠标停留在 Dock 图标上可显示窗口预览。
        • 点击某个预览可直接恢复并激活对应窗口。
        • 全屏窗口保留 macOS 原生 Dock 行为，不会被 WinMan 强制最小化。
        """, font: .systemFont(ofSize: 13))

        section("Finder")
        append("""
        Finder 使用独立的 System Events 处理逻辑。无论通过 Cmd-M、黄色最小化按钮，
        还是 WinMan 的 Dock 点击最小化，都可以再次点击 Finder 图标恢复窗口。
        """, font: .systemFont(ofSize: 13))

        section("权限")
        append("""
        • 辅助功能：必须，用于读取和改变窗口状态。
        • 自动化：必须，用于通过 System Events 读取 Dock 和管理 Finder。
        • 屏幕录制：可选，仅用于显示实时窗口缩略图；拒绝后仍可使用窗口切换。

        如果点击没有反应，请先在菜单中打开对应的系统设置并确认 WinMan 已授权。
        更换签名身份时可能需要最后重新授权一次；以后使用相同签名编译不会反复失效。
        """, font: .systemFont(ofSize: 13))

        section("设置")
        append("""
        可单独关闭 Dock 点击切换或悬停预览，也可以调整悬停延迟。
        “登录时自动启动”由用户自行开启，WinMan 不再在每次启动时强制注册登录项。
        """, font: .systemFont(ofSize: 13))

        section("故障排查")
        append("""
        • 权限正常但功能失效：退出并重新打开 WinMan。
        • 只有缩略图不可见：检查屏幕录制权限。
        • Dock 移动、缩放或自动隐藏后：移动鼠标几秒，WinMan 会自动刷新图标位置。
        • 从 GitHub 首次下载的未公证版本：可在 Finder 中右键应用并选择“打开”。
        """, font: .systemFont(ofSize: 13))

        section("作者与项目")
        append("作者：Guohongbo\n联系：ghbhiee@gmail.com\nGitHub：",
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
        }
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
            guard !delegate.skippedApps.contains(dockItem.name) else { return false }
            guard AXIsProcessTrusted() else { return false }

            let apps = NSWorkspace.shared.runningApplications
            guard let app = apps.first(where: { delegate.matches(app: $0, dockName: dockItem.name) }) else {
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

            if delegate.hoveredDockItem?.name != dockItem.name {
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
        guard let app = apps.first(where: { self.matches(app: $0, dockName: dockItem.name) }) else { return }

        // Put the tracked active window first, then fall back to system Z-order.
        let axWindows = windowTracker.windowsInInteractionOrder(for: app)
        guard axWindows.count >= 2 else { return }

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
                      self.hoveredDockItem?.name == dockItem.name,
                      Date() >= self.suppressPreviewUntil else { return }

                if self.previewPanel == nil { self.previewPanel = PreviewPanel() }

                self.previewPanel?.show(
                    for: app, windows: readyItems, nearDockRect: dockItem.rect
                ) { [weak self] element, app in
                    self?.previewPanel?.dismiss()
                    self?.windowTracker.setLastActiveWindow(element, for: app)
                    if self?.windowTracker.restoreAndRaise(element, app: app) == false {
                        NSSound.beep()
                    }
                }
            }
        }
    }

    // MARK: - App name matching

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

    func promptForAccessibilityPermission() {
        let alert = NSAlert()
        alert.messageText = "Accessibility Permission Required"
        alert.informativeText = "WinMan needs Accessibility permission to manage windows.\n\nPlease grant access in System Preferences, then relaunch."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Open Preferences")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openAccessibilityPreferences()
        }
    }

    func openAccessibilityPreferences() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
        ) else { return }
        NSWorkspace.shared.open(url)
    }

    func openAutomationPreferences() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
        ) else { return }
        NSWorkspace.shared.open(url)
    }
}
