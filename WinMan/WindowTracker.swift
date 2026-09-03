import Cocoa
import ApplicationServices
import os

// Private AX API to get CGWindowID from AXUIElement — widely used by Rectangle, Hammerspoon, etc.
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

// AX attribute strings not exposed as constants in the current SDK
private let kAXFullScreenAttribute = "AXFullScreen" as CFString
private let kAXMinimizedWindowsAttribute = "AXMinimizedWindows" as CFString

/// Private SkyLight entry points that bring ONE window of an app to the front
/// without the app-level activation that drags every other window of that app
/// along. Same technique as AltTab and yabai. Resolved with dlsym so a missing
/// symbol degrades to the public activate() path instead of failing to link.
private enum SkyLight {
    typealias SetFrontProcessFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
    typealias PostEventRecordFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>
    ) -> CGError
    typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    static let userGeneratedMode: UInt32 = 0x200  // kCPSUserGenerated

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_NOW
    )
    static let setFrontProcess: SetFrontProcessFn? = load("_SLPSSetFrontProcessWithOptions", from: handle)
    static let postEventRecord: PostEventRecordFn? = load("SLPSPostEventRecordTo", from: handle)
    // Deprecated Carbon API, unavailable to Swift by name but still exported.
    static let getProcessForPID: GetProcessForPIDFn? = load("GetProcessForPID", from: dlopen(nil, RTLD_NOW))

    static var isAvailable: Bool {
        setFrontProcess != nil && postEventRecord != nil && getProcessForPID != nil
    }

    private static func load<T>(_ symbol: String, from handle: UnsafeMutableRawPointer?) -> T? {
        guard let handle, let pointer = dlsym(handle, symbol) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }
}

class WindowTracker {
    // bundleID → last focused window element
    private var lastActiveWindows: [String: AXUIElement] = [:]

    // bundleID → deadline. While set, focus notifications from that app are
    // ignored: minimizing window A makes macOS focus sibling B, and recording
    // B would make the next Dock click act on the wrong window.
    private var focusTrackingSuppressedUntil: [String: Date] = [:]

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
            guard let self, !self.isFocusTrackingSuppressed(for: bundleID) else { return }
            if let window = self.currentFocusedWindow(for: app) {
                self.lastActiveWindows[bundleID] = window
                WinManLog.tracker.debug("Tracked window for \(app.localizedName ?? bundleID, privacy: .public)")
            }
        }
    }

    /// Ignore the app's focus notifications for a short while after WinMan
    /// itself changes its windows, so side-effect focus moves (macOS focusing a
    /// sibling after a minimize) don't overwrite the window WinMan is managing.
    func suppressFocusTracking(for app: NSRunningApplication, interval: TimeInterval = 0.8) {
        guard let bundleID = app.bundleIdentifier else { return }
        focusTrackingSuppressedUntil[bundleID] = Date().addingTimeInterval(interval)
    }

    private func isFocusTrackingSuppressed(for bundleID: String) -> Bool {
        guard let until = focusTrackingSuppressedUntil[bundleID] else { return false }
        if Date() < until { return true }
        focusTrackingSuppressedUntil.removeValue(forKey: bundleID)
        return false
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
        guard !isFocusTrackingSuppressed(for: bundleID) else {
            WinManLog.tracker.debug("Focus change ignored (suppressed) for \(bundleID, privacy: .public)")
            return
        }
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

    /// Windows that count as user-facing "views" in single-view mode: real
    /// standard windows with a CGWindowID. Filters out dialogs, sheets, and
    /// phantom entries such as Finder's desktop (no ID, no subrole).
    func standardWindowsInInteractionOrder(for app: NSRunningApplication) -> [AXUIElement] {
        windowsInInteractionOrder(for: app).filter(isStandardWindow)
    }

    func isStandardWindow(_ window: AXUIElement) -> Bool {
        guard windowID(window) != nil else { return false }
        // Finder (and possibly others) report a minimized window's subrole as
        // AXDialog until it is restored, so only judge subrole while visible.
        return windowSubrole(window) == kAXStandardWindowSubrole || isMinimized(window)
    }

    func windowSubrole(_ window: AXUIElement) -> String? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &result) == .success else { return nil }
        return result as? String
    }

    /// True when `window` is the app's currently focused window.
    func isFocused(_ window: AXUIElement, in app: NSRunningApplication) -> Bool {
        guard let focused = currentFocusedWindow(for: app) else { return false }
        return isSameWindow(window, focused)
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
            } else {
                // No CGWindowID and no subrole is a phantom (Finder's desktop);
                // ID-less windows with a subrole are real (some Electron apps).
                guard windowSubrole(window) != nil else { return }
                if windows.contains(where: { CFEqual($0, window) }) { return }
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

    /// Closes a window by pressing its close button — equivalent to the user
    /// clicking the red button, so "are you sure" sheets still appear.
    @discardableResult
    func closeWindow(_ window: AXUIElement) -> Bool {
        var button: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &button) == .success,
              let button else { return false }
        return AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString) == .success
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

    /// Brings exactly one window to the front — single-view semantics. The
    /// app's other windows keep their place in the global Z-order instead of
    /// being dragged forward by app activation. Un-minimizes and un-hides as
    /// needed. Falls back to restoreAndRaise when the private API is missing
    /// or the window has no CGWindowID.
    @discardableResult
    func focusWindow(_ window: AXUIElement, app: NSRunningApplication) -> Bool {
        guard SkyLight.isAvailable,
              let setFront = SkyLight.setFrontProcess,
              let postEvent = SkyLight.postEventRecord,
              let getPSN = SkyLight.getProcessForPID,
              let wid = windowID(window) else {
            return restoreAndRaise(window, app: app)
        }

        if isMinimized(window) {
            AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        }
        if app.isHidden {
            app.unhide()
        }

        var psn = ProcessSerialNumber()
        guard getPSN(app.processIdentifier, &psn) == noErr,
              setFront(&psn, wid, SkyLight.userGeneratedMode) == .success else {
            WinManLog.tracker.error("SkyLight focus failed for wid \(wid); falling back to activate")
            return restoreAndRaise(window, app: app)
        }

        // Synthetic left-mouse-down CGSEventRecord addressed to the window by
        // id, which makes it key without clicking its content. Layout follows
        // AltTab's makeKeyWindow as verified on macOS 26.5:
        //  - buffer is 0x100 although the record declares 0xf8: WindowServer on
        //    macOS 14.7.4+ reads past the record, so the tail must be zeroed;
        //  - a single mouse-down only (no up), so no control can ever be
        //    activated by a half-click;
        //  - windowLocation is a real point far past the bottom-right corner
        //    (the old 0xFF NaN fill is sanitized to (0,0) by some apps, which
        //    then clicks whatever sits at their top-left).
        var bytes = [UInt8](repeating: 0, count: 0x100)
        bytes[0x04] = 0xF8                       // declared record length
        bytes[0x08] = 0x01                       // kCGEventLeftMouseDown
        bytes[0x3a] = 0x10                       // undocumented flag (yabai/Hammerspoon)
        var widCopy = wid
        memcpy(&bytes[0x3c], &widCopy, MemoryLayout<CGWindowID>.size)
        var point = CGPoint(x: 300_000, y: 300_000)
        memcpy(&bytes[0x20], &point, MemoryLayout<CGPoint>.size)
        _ = bytes.withUnsafeMutableBufferPointer { buffer in
            postEvent(&psn, buffer.baseAddress!)
        }

        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        return true
    }

    func isSameWindow(_ lhs: AXUIElement, _ rhs: AXUIElement) -> Bool {
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
