import Cocoa
import ApplicationServices
import os

// Private AX API to get CGWindowID from AXUIElement — widely used by Rectangle, Hammerspoon, etc.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// AX attribute strings not exposed as constants in the current SDK
private let kAXFullScreenAttribute = "AXFullScreen" as CFString
private let kAXMinimizedWindowsAttribute = "AXMinimizedWindows" as CFString

class WindowTracker {
    // bundleID → last focused window element
    private var lastActiveWindows: [String: AXUIElement] = [:]

    // AXObserver on the frontmost app: the system pushes focus changes to us
    // the moment they happen, covering keyboard switching (Cmd-`), Mission
    // Control, and window clicks — paths the click-probe fallback misses.
    private var focusObserver: AXObserver?
    private var observedAppElement: AXUIElement?
    private var observedPID: pid_t = -1
    private var observedBundleID: String?
    private static let focusNotifications: [CFString] = [
        kAXFocusedWindowChangedNotification as CFString,
        kAXMainWindowChangedNotification as CFString,
    ]

    func startTracking() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )
        if let front = NSWorkspace.shared.frontmostApplication {
            observeFocus(of: front)
        }
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }

        observeFocus(of: app)

        // Initial read at activation — the observer only reports changes that
        // happen after registration. Small delay: kAXFocusedWindowAttribute
        // may not be set yet right at activation.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            if let window = self?.currentFocusedWindow(for: app) {
                self?.lastActiveWindows[bundleID] = window
                WinManLog.tracker.debug("Tracked window for \(app.localizedName ?? bundleID, privacy: .public)")
            }
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeFocusObserver()
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        if app.processIdentifier == observedPID {
            removeFocusObserver()
        }
        guard let bundleID = app.bundleIdentifier else { return }
        lastActiveWindows.removeValue(forKey: bundleID)
    }

    // MARK: - Focus observation

    private func observeFocus(of app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard pid != observedPID else { return }
        removeFocusObserver()

        guard AXIsProcessTrusted(), let bundleID = app.bundleIdentifier else { return }

        var created: AXObserver?
        let callback: AXObserverCallback = { _, element, _, refcon in
            guard let refcon else { return }
            Unmanaged<WindowTracker>.fromOpaque(refcon)
                .takeUnretainedValue()
                .handleFocusChange(window: element)
        }
        guard AXObserverCreate(pid, callback, &created) == .success, let observer = created else {
            WinManLog.tracker.debug("AXObserverCreate failed for pid \(pid)")
            return
        }

        let appElement = AXUIElementCreateApplication(pid)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        var registered = false
        for notification in Self.focusNotifications {
            if AXObserverAddNotification(observer, appElement, notification, refcon) == .success {
                registered = true
            }
        }
        // Some apps expose no AX notifications at all; leave observedPID unset
        // so the next activation retries (also covers permission granted late).
        guard registered else { return }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        focusObserver = observer
        observedAppElement = appElement
        observedPID = pid
        observedBundleID = bundleID
    }

    private func removeFocusObserver() {
        if let observer = focusObserver {
            if let appElement = observedAppElement {
                for notification in Self.focusNotifications {
                    AXObserverRemoveNotification(observer, appElement, notification)
                }
            }
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        focusObserver = nil
        observedAppElement = nil
        observedPID = -1
        observedBundleID = nil
    }

    /// Called on the main run loop whenever the observed app's focused or main
    /// window changes; `window` is the window element that gained focus.
    private func handleFocusChange(window: AXUIElement) {
        guard let bundleID = observedBundleID else { return }
        lastActiveWindows[bundleID] = window
        WinManLog.tracker.debug("Focus change tracked for \(bundleID, privacy: .public)")
    }

    func lastActiveWindow(for app: NSRunningApplication) -> AXUIElement? {
        guard let bundleID = app.bundleIdentifier else { return nil }
        return lastActiveWindows[bundleID]
    }

    func lastActiveWindow(in windows: [AXUIElement], for app: NSRunningApplication) -> AXUIElement? {
        guard let lastWindow = lastActiveWindow(for: app) else { return nil }
        return windows.first { isSameWindow($0, lastWindow) }
    }

    func windowsInInteractionOrder(for app: NSRunningApplication) -> [AXUIElement] {
        var windows = windowsInZOrder(for: app)
        guard let lastWindow = lastActiveWindow(in: windows, for: app),
              let index = windows.firstIndex(where: { isSameWindow($0, lastWindow) }) else {
            return windows
        }

        windows.remove(at: index)
        windows.insert(lastWindow, at: 0)
        return windows
    }

    func setLastActiveWindow(_ window: AXUIElement, for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        lastActiveWindows[bundleID] = window
    }

    func currentFocusedWindow(for app: NSRunningApplication) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var result: CFTypeRef?
        let err = AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &result)
        guard err == .success, let window = result else { return nil }
        return (window as! AXUIElement)
    }

    /// Returns windows sorted by Z-order (most recently used first) using CGWindowList.
    /// Minimized windows (not in CGWindowList) are appended at the end.
    func windowsInZOrder(for app: NSRunningApplication) -> [AXUIElement] {
        let axWindows = allWindows(for: app)
        guard !axWindows.isEmpty else { return [] }

        // CGWindowList returns on-screen windows front-to-back (most recent first)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let cgList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return axWindows
        }

        let orderedIDs: [CGWindowID] = cgList.compactMap { info in
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  pid == app.processIdentifier,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID else { return nil }
            return wid
        }

        // Resolve each window's CGWindowID once — _AXUIElementGetWindow is an
        // out-of-process round trip, so avoid repeating it per comparison.
        let axPairs: [(element: AXUIElement, id: CGWindowID?)] =
            axWindows.map { ($0, windowID($0)) }

        var usedIndices = Set<Int>()
        var result: [AXUIElement] = []
        // First: visible windows in Z-order
        for wid in orderedIDs {
            guard let index = axPairs.firstIndex(where: { $0.id == wid }),
                  !usedIndices.contains(index) else { continue }
            usedIndices.insert(index)
            result.append(axPairs[index].element)
        }
        // Then append every remaining AX window. This preserves windows that do
        // not expose a CGWindowID, which is common in some Electron applications.
        for (index, pair) in axPairs.enumerated() where !usedIndices.contains(index) {
            result.append(pair.element)
        }
        return result
    }

    /// Returns all windows for an app, including minimized ones
    func allWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windows: [AXUIElement] = []
        // Dedupe by CGWindowID resolved once per window; CFEqual is only the
        // fallback for windows that expose no ID.
        var seenIDs = Set<CGWindowID>()

        func appendIfNew(_ window: AXUIElement) {
            if let wid = windowID(window) {
                guard seenIDs.insert(wid).inserted else { return }
            } else if windows.contains(where: { CFEqual($0, window) }) {
                return
            }
            windows.append(window)
        }

        var result: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &result) == .success,
           let list = result as? [AXUIElement] {
            list.forEach(appendIfNew)
        }

        // Also get minimized windows (not always in kAXWindowsAttribute on macOS 14+)
        var minResult: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMinimizedWindowsAttribute, &minResult) == .success,
           let minList = minResult as? [AXUIElement] {
            minList.forEach(appendIfNew)
        }

        return windows
    }

    func windowTitle(_ window: AXUIElement) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &result) == .success else { return nil }
        return result as? String
    }

    func windowID(_ window: AXUIElement) -> CGWindowID? {
        var wid: CGWindowID = 0
        let err = _AXUIElementGetWindow(window, &wid)
        guard err == .success, wid != 0 else { return nil }
        return wid
    }

    func isMinimized(_ window: AXUIElement) -> Bool {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &result) == .success else { return false }
        return (result as? Bool) ?? false
    }

    func isFullscreen(_ window: AXUIElement) -> Bool {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXFullScreenAttribute, &result) == .success else { return false }
        return (result as? Bool) ?? false
    }

    @discardableResult
    func minimizeWindow(_ window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            true as CFTypeRef
        ) == .success
    }

    @discardableResult
    func restoreAndRaise(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        let restoreResult = AXUIElementSetAttributeValue(
            window,
            kAXMinimizedAttribute as CFString,
            false as CFTypeRef
        )

        let raiseResult = AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        let mainResult = AXUIElementSetAttributeValue(
            window,
            kAXMainAttribute as CFString,
            true as CFTypeRef
        )
        let activated = app.activate(options: .activateIgnoringOtherApps)

        let restored = restoreResult == .success || restoreResult == .attributeUnsupported
        let raised = raiseResult == .success || mainResult == .success
        return restored && raised && activated
    }

    private func isSameWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
        if let lhsID = windowID(lhs), let rhsID = windowID(rhs) {
            return lhsID == rhsID
        }
        return CFEqual(lhs, rhs)
    }

    func debugDump() {
        print("[WindowTracker] Last active windows:")
        for (bundleID, window) in lastActiveWindows {
            let title = windowTitle(window) ?? "(no title)"
            let wid = windowID(window).map { "\($0)" } ?? "nil"
            print("  \(bundleID): \"\(title)\" (wid=\(wid))")
        }
    }

    func showDebugAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let lines = lastActiveWindows.map { (bundleID, window) -> String in
            let title = windowTitle(window) ?? "(no title)"
            let wid = windowID(window).map { "\($0)" } ?? "nil"
            return "• \(bundleID)\n  \"\(title)\"  wid=\(wid)"
        }
        let body = lines.isEmpty ? "(no windows tracked yet)" : lines.joined(separator: "\n")
        let alert = NSAlert()
        alert.messageText = "Tracked Windows (\(lastActiveWindows.count))"
        alert.informativeText = body
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
