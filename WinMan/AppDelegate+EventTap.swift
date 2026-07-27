import Cocoa
import CoreGraphics
import ApplicationServices

// Event tap lifecycle plus left/right click handling. The tap runs on the main
// run loop; every handler here executes on the main thread.
extension AppDelegate {

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
            (1 << CGEventType.mouseMoved.rawValue) |
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

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
        case .keyDown:
            if AppDelegate.handleSwitcherKeyDown(event: event, delegate: delegate) {
                return nil
            }
        case .flagsChanged:
            // Releasing Option while the switcher is open commits the selection.
            if delegate.windowSwitcher.isActive, !event.flags.contains(.maskAlternate) {
                delegate.windowSwitcher.commit()
            }
        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    // MARK: - Option-Tab switcher keys

    private static let tabKeyCode: Int64 = 48
    private static let escapeKeyCode: Int64 = 53

    /// Returns true when the key event belongs to the switcher and must be
    /// swallowed instead of reaching the frontmost app.
    static func handleSwitcherKeyDown(event: CGEvent, delegate: AppDelegate) -> Bool {
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let reversed = event.flags.contains(.maskShift)

        if delegate.windowSwitcher.isActive {
            switch keyCode {
            case tabKeyCode:
                delegate.windowSwitcher.cycle(reversed: reversed)
                return true
            case escapeKeyCode:
                delegate.windowSwitcher.cancel()
                return true
            default:
                return false
            }
        }

        guard delegate.isSwitcherEnabled,
              keyCode == tabKeyCode,
              event.flags.contains(.maskAlternate),
              !event.flags.contains(.maskCommand),
              !event.flags.contains(.maskControl) else { return false }

        delegate.windowSwitcher.begin(reversed: reversed)
        return delegate.windowSwitcher.isActive
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
                delegate.suppressPreviewAfterAction(for: 1.5)
                return true
            }

            let orderedWindows = delegate.windowTracker.windowsInInteractionOrder(for: app)
            let freshWindow = isFrontmost && !app.isHidden
                ? delegate.windowTracker.currentFocusedWindow(for: app)
                : nil
            let window = freshWindow ?? orderedWindows.first
            let windowIsMinimized = window.map { delegate.windowTracker.isMinimized($0) } ?? false

            let action = DockClickPolicy.action(
                isFrontmost: isFrontmost,
                isAppHidden: app.isHidden,
                hasWindow: window != nil,
                windowIsMinimized: windowIsMinimized,
                windowIsFullscreen: window.map { delegate.windowTracker.isFullscreen($0) } ?? false
            )

            WinManLog.app.debug("\(app.localizedName ?? dockItem.name, privacy: .public) frontmost=\(isFrontmost) minimized=\(windowIsMinimized) action=\(String(describing: action), privacy: .public)")

            let handled: Bool
            switch action {
            case .passThrough:
                return false
            case .minimize:
                guard let window else { return false }
                delegate.windowTracker.setLastActiveWindow(window, for: app)
                handled = delegate.windowTracker.minimizeWindow(window)
            case .restore:
                guard let window else { return false }
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

            delegate.suppressPreviewAfterAction(for: 1.5)
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
        delegate.hoveredDockItem = nil
        // Suppress for 2s so preview doesn't appear over the context menu
        delegate.suppressPreviewAfterAction(for: 2.0)
    }
}
