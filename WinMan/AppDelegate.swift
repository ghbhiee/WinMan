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

/// UserDefaults reads with an explicit default for keys the user never touched.
/// Every read path must use this: plain bool(forKey:) turns a missing key into
/// false, which once silently disabled click toggling and previews the first
/// time any other setting was changed.
enum Settings {
    static func bool(_ key: String, default defaultValue: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) == nil
            ? defaultValue
            : UserDefaults.standard.bool(forKey: key)
    }

    static var hoverDelay: Double {
        let value = UserDefaults.standard.double(forKey: "HoverDelay")
        return value == 0 ? 0.5 : value
    }
}

/// The allowlist of apps that get single-view (Windows-taskbar-style)
/// management: hover previews, per-window focus without dragging siblings
/// forward, and a pinned toggle target. Everything else stays native.
enum ManagedApps {
    static let defaultsKey = "ManagedBundleIDs"
    static let defaultBundleIDs = ["com.apple.finder", "com.google.Chrome"]

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: defaultsKey) ?? defaultBundleIDs
    }

    static func save(_ bundleIDs: [String]) {
        UserDefaults.standard.set(bundleIDs, forKey: defaultsKey)
        NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
    }

    static func appURL(for bundleID: String) -> URL? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.bundleURL
            ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static func displayName(for bundleID: String) -> String {
        if let running = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first,
           let name = running.localizedName {
            return name
        }
        if let url = appURL(for: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
                .replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    static func icon(for bundleID: String) -> NSImage? {
        appURL(for: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
    }

    /// Running regular apps not yet on the list, for the "add" menu.
    static func candidates(excluding existing: [String]) -> [(bundleID: String, name: String)] {
        let taken = Set(existing)
        let me = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier, id != me,
                  !taken.contains(id), seen.insert(id).inserted else { return nil }
            return (id, app.localizedName ?? id)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
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
    lazy var windowSwitcher = WindowSwitcher(windowTracker: windowTracker)
    var previewPanel: PreviewPanel?
    private var userRequestedQuit = false
    // Internal (not private): these are used by the AppDelegate extensions in
    // AppDelegate+EventTap.swift, +HoverPreview.swift, and +Help.swift.
    var eventTapRetryWorkItem: DispatchWorkItem?
    let previewBuildQueue = DispatchQueue(
        label: "com.winman.preview-thumbnails",
        qos: .userInitiated
    )
    let githubURL = URL(string: "https://github.com/ghbhiee/WinMan")!

    // Settings
    var isToggleEnabled = Settings.bool("ToggleEnabled", default: true)
    var isPreviewEnabled = Settings.bool("PreviewEnabled", default: true)
    var isSingleWindowPreviewEnabled = Settings.bool("PreviewSingleWindow", default: false)
    var isSwitcherEnabled = Settings.bool("SwitcherEnabled", default: true)
    var hoverDelay = Settings.hoverDelay
    var managedBundleIDs: Set<String> = Set(ManagedApps.load())

    func isManaged(_ dockItem: DockItem) -> Bool {
        dockItem.bundleID.map(managedBundleIDs.contains) ?? false
    }

    func isManaged(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(managedBundleIDs.contains) ?? false
    }

    // Hover state
    var hoverTimer: Timer?
    var hoveredDockItem: DockItem?
    var dismissPreviewTimer: Timer?

    // Aero-Peek state: the window temporarily brought forward while its
    // thumbnail is hovered (see AppDelegate+HoverPreview.swift).
    var peek: PeekState?
    var peekStartTimer: Timer?
    var peekRestoreTimer: Timer?

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
        isToggleEnabled = Settings.bool("ToggleEnabled", default: true)
        isPreviewEnabled = Settings.bool("PreviewEnabled", default: true)
        isSingleWindowPreviewEnabled = Settings.bool("PreviewSingleWindow", default: false)
        isSwitcherEnabled = Settings.bool("SwitcherEnabled", default: true)
        hoverDelay = Settings.hoverDelay
        managedBundleIDs = Set(ManagedApps.load())
        WinManLog.app.info("Settings reloaded: toggle=\(self.isToggleEnabled) preview=\(self.isPreviewEnabled) switcher=\(self.isSwitcherEnabled) delay=\(self.hoverDelay) managed=\(self.managedBundleIDs.count)")
    }

    // MARK: - Settings window

    func openSettings() {
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            let hosting = NSHostingController(rootView: ContentView())
            // The allowlist grows and shrinks; let the window follow content.
            hosting.sizingOptions = .preferredContentSize
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
}
