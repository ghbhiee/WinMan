import Cocoa
import ApplicationServices

// Private AX API to get CGWindowID from AXUIElement — widely used by Rectangle, Hammerspoon, etc.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// AX attribute strings not exposed as constants in the current SDK
private let kAXFullScreenAttribute = "AXFullScreen" as CFString
private let kAXMinimizedWindowsAttribute = "AXMinimizedWindows" as CFString

class WindowTracker {
    // bundleID → last focused window element
    private var lastActiveWindows: [String: AXUIElement] = [:]

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
    }

    @objc private func appActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }

        // Small delay: kAXFocusedWindowAttribute may not be set yet right at activation
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            if let window = self?.currentFocusedWindow(for: app) {
                self?.lastActiveWindows[bundleID] = window
                print("[WindowTracker] Tracked window for \(app.localizedName ?? bundleID)")
            }
        }
    }

    @objc private func appTerminated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleID = app.bundleIdentifier else { return }
        lastActiveWindows.removeValue(forKey: bundleID)
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

        var result: [AXUIElement] = []
        // First: visible windows in Z-order
        for wid in orderedIDs {
            if let ax = axWindows.first(where: { windowID($0) == wid }),
               !result.contains(where: { isSameWindow($0, ax) }) {
                result.append(ax)
            }
        }
        // Then append every remaining AX window. This preserves windows that do
        // not expose a CGWindowID, which is common in some Electron applications.
        for ax in axWindows {
            if !result.contains(where: { isSameWindow($0, ax) }) {
                result.append(ax)
            }
        }
        return result
    }

    /// Returns all windows for an app, including minimized ones
    func allWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windows: [AXUIElement] = []

        var result: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &result) == .success,
           let list = result as? [AXUIElement] {
            for window in list where !windows.contains(where: { isSameWindow($0, window) }) {
                windows.append(window)
            }
        }

        // Also get minimized windows (not always in kAXWindowsAttribute on macOS 14+)
        var minResult: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXMinimizedWindowsAttribute, &minResult) == .success,
           let minList = minResult as? [AXUIElement] {
            for window in minList {
                if !windows.contains(where: { isSameWindow($0, window) }) {
                    windows.append(window)
                }
            }
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
