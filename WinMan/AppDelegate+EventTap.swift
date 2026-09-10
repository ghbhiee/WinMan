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
            (1 << CGEventType.keyUp.rawValue) |
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
            if AppDelegate.handlePreviewKeyDown(event: event, delegate: delegate) {
                delegate.swallowedKeyCodes.insert(event.getIntegerValueField(.keyboardEventKeycode))
                return nil
            }
            if AppDelegate.handleSwitcherKeyDown(event: event, delegate: delegate) {
                delegate.swallowedKeyCodes.insert(event.getIntegerValueField(.keyboardEventKeycode))
                return nil
            }
        case .keyUp:
            // Complete the swallow: an app must not receive a key-up for a
            // key-down it never saw.
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            if delegate.swallowedKeyCodes.remove(code) != nil {
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

    /// Virtual key codes of the digit keys (main row and keypad) → 1…9.
    private static let digitKeyCodes: [Int64: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
    ]

    /// While a preview row is open: Escape closes it, and a plain digit picks
    /// that card. Both are swallowed, so the frontmost app never sees the
    /// keystroke and its cursor/state stay untouched.
    static func handlePreviewKeyDown(event: CGEvent, delegate: AppDelegate) -> Bool {
        guard delegate.previewPanel?.isVisible == true,
              !delegate.windowSwitcher.isActive else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == escapeKeyCode {
            delegate.suppressPreviewAfterAction(for: 1.0)
            return true
        }
        let plain = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty
        if plain, let number = digitKeyCodes[keyCode] {
            return delegate.selectPreviewItem(number: number)
        }
        return false
    }

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
            if delegate.isManaged(app) {
                return handleManagedClick(app: app, isFrontmost: isFrontmost, delegate: delegate)
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

            delegate.suppressPreviewAfterAction(for: 1.0)
            return true
        }
        return false
    }

    /// Single-view mode for allowlisted apps. The toggle target is the window
    /// WinMan last acted on (pinned via focus-tracking suppression), so a
    /// minimize followed by a click always brings back that same window, and
    /// focusing never drags the app's other windows forward.
    private static func handleManagedClick(
        app: NSRunningApplication,
        isFrontmost: Bool,
        delegate: AppDelegate
    ) -> Bool {
        let tracker = delegate.windowTracker
        // Last-active first, then global Z-order; standard windows only.
        let target = tracker.standardWindowsInInteractionOrder(for: app).first

        let action = ManagedClickPolicy.action(
            hasTarget: target != nil,
            targetIsMinimized: target.map(tracker.isMinimized) ?? false,
            targetIsFullscreen: target.map(tracker.isFullscreen) ?? false,
            targetIsFocused: target.map { tracker.isFocused($0, in: app) } ?? false,
            isFrontmost: isFrontmost,
            isAppHidden: app.isHidden
        )

        WinManLog.app.debug("[managed] \(app.localizedName ?? "?", privacy: .public) frontmost=\(isFrontmost) action=\(String(describing: action), privacy: .public)")

        guard let target, action != .passThrough else { return false }

        // Pin the target before acting so the focus side effects of the action
        // (macOS focusing a sibling after a minimize) cannot replace it.
        tracker.setLastActiveWindow(target, for: app)
        tracker.suppressFocusTracking(for: app)

        let handled: Bool
        switch action {
        case .minimize:
            handled = tracker.minimizeWindow(target)
        case .restore, .focus:
            handled = tracker.focusWindow(target, app: app)
        case .passThrough:
            return false
        }

        guard handled else {
            WinManLog.app.debug("[managed] window operation failed; passing the Dock click through")
            return false
        }
        delegate.suppressPreviewAfterAction(for: 1.0)
        return true
    }

    func rememberFrontmostWindowAfterUserClick() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            guard let self = self,
                  let app = NSWorkspace.shared.frontmostApplication,
                  let window = self.windowTracker.currentFocusedWindow(for: app) else { return }
            self.windowTracker.setLastActiveWindow(window, for: app)
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
