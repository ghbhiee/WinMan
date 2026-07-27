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
    // Internal (not private): these are used by the AppDelegate extensions in
    // AppDelegate+EventTap.swift, +HoverPreview.swift, and +Help.swift.
    var eventTapRetryWorkItem: DispatchWorkItem?
    let finderAutomationQueue = DispatchQueue(
        label: "com.winman.finder-automation",
        qos: .userInitiated
    )
    let previewBuildQueue = DispatchQueue(
        label: "com.winman.preview-thumbnails",
        qos: .userInitiated
    )
    let githubURL = URL(string: "https://github.com/ghbhiee/WinMan")!

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

    func openAutomationPreferences() {
        openSecurityPane("Privacy_Automation")
    }
}
