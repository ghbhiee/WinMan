import Cocoa
import CoreGraphics

// Hover state machine and preview panel orchestration. Decisions come from
// HoverPolicy; this file owns the timers and panel side effects.
extension AppDelegate {

    func dismissPreview() {
        previewPanel?.dismiss()
    }

    /// After a click or right-click action, hover preview is suppressed for a
    /// short time. Time-based suppression never gets permanently stuck unlike
    /// an exit-gate boolean.
    func suppressPreviewAfterAction(for interval: TimeInterval) {
        suppressPreviewUntil = Date().addingTimeInterval(interval)
        hoverTimer?.invalidate()
        hoverTimer = nil
        dismissPreviewTimer?.invalidate()
        dismissPreviewTimer = nil
        dismissPreview()
    }

    static func handleMouseMoved(location: CGPoint, delegate: AppDelegate) {
        delegate.dockMonitor.refreshIfNeeded(near: location)

        let hitItem = delegate.dockMonitor.items.first(where: { $0.rect.contains(location) })
        let response = HoverPolicy.response(
            hitItemIdentity: hitItem?.identity,
            hitItemIsManaged: hitItem.map(delegate.isManaged) ?? false,
            hoveredIdentity: delegate.hoveredDockItem?.identity,
            isOverPanel: delegate.isLocationOverPanel(location),
            isSuppressed: Date() < delegate.suppressPreviewUntil
        )

        switch response {
        case .suppressed:
            // Cancel any hover timer that might be running, but don't start a new one
            delegate.hoverTimer?.invalidate()
            delegate.hoverTimer = nil

        case .beginHover:
            // Moved to a different dock item — dismiss previous panel and restart timer
            guard let dockItem = hitItem else { return }
            // Like the Windows taskbar: once a preview is up, sliding to the
            // next icon switches previews immediately instead of re-waiting.
            let delay = delegate.previewPanel?.isVisible == true ? 0.08 : delegate.hoverDelay
            delegate.dismissPreviewTimer?.invalidate()
            delegate.dismissPreviewTimer = nil
            delegate.hoverTimer?.invalidate()
            delegate.dismissPreview()
            delegate.hoveredDockItem = dockItem

            delegate.hoverTimer = Timer.scheduledTimer(
                withTimeInterval: delay,
                repeats: false
            ) { [weak delegate] _ in
                guard let delegate = delegate else { return }
                DispatchQueue.main.async { delegate.showPreview(for: dockItem) }
            }

        case .stayOnItem, .stayOnPanel:
            // Keep the panel alive — cancel any pending dismiss
            delegate.dismissPreviewTimer?.invalidate()
            delegate.dismissPreviewTimer = nil

        case .leftHoverArea:
            delegate.hoverTimer?.invalidate()
            delegate.hoverTimer = nil
            delegate.hoveredDockItem = nil

            if delegate.previewPanel?.isVisible == true, delegate.dismissPreviewTimer == nil {
                delegate.dismissPreviewTimer = Timer.scheduledTimer(
                    withTimeInterval: 0.4,
                    repeats: false
                ) { [weak delegate] _ in
                    DispatchQueue.main.async { delegate?.dismissPreview() }
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
        guard isPreviewEnabled, isManaged(dockItem) else { return }

        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { self.matches(app: $0, dockItem: dockItem) }) else { return }

        // Fixed order (creation order) so cards never shuffle; the last-active
        // window — what a Dock click toggles — is flagged instead.
        let axWindows = windowTracker.standardWindowsInStableOrder(for: app)
        guard axWindows.count >= minimumPreviewWindowCount else { return }
        let lastActive = windowTracker.lastActiveWindow(in: axWindows, for: app)
        let screenLabels = screenLabelsByWindowID(for: app)

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
                thumbnail: nil, isMinimized: minimized, windowID: wid,
                isLastActive: lastActive.map { windowTracker.isSameWindow($0, axWindow) } ?? false,
                screenLabel: wid.flatMap { screenLabels[$0] }
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
                        guard let self else { return }
                        self.dismissPreview()
                        // Single-view: bring up only the chosen window and pin it.
                        self.windowTracker.setLastActiveWindow(element, for: app)
                        self.windowTracker.suppressFocusTracking(for: app)
                        if !self.windowTracker.focusWindow(element, app: app) {
                            NSSound.beep()
                        }
                    },
                    onCloseWindow: { [weak self] item in
                        self?.closeWindowFromPreview(item, app: app, dockItem: dockItem)
                    },
                    onMinimizeWindow: { [weak self] item in
                        self?.toggleMinimizeFromPreview(item, app: app, dockItem: dockItem)
                    },
                    onMinimizeOthers: { [weak self] item in
                        self?.keepOnlyWindowFromPreview(item, app: app)
                    }
                )
            }
        }
    }

    /// "2 · LG UltraFine"-style label per window, only when several displays
    /// are attached. Uses the window's last known bounds so minimized windows
    /// are labeled too.
    private func screenLabelsByWindowID(for app: NSRunningApplication) -> [CGWindowID: String] {
        let screens = NSScreen.screens
        guard screens.count > 1, let primary = screens.first?.frame else { return [:] }
        let list = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]]) ?? []
        var labels: [CGWindowID: String] = [:]
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid == app.processIdentifier,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary) else { continue }
            let rect = ScreenGeometry.appKitRect(fromQuartz: bounds, primaryScreenFrame: primary)
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let index = screens.firstIndex(where: { $0.frame.contains(center) })
                ?? screens.firstIndex(where: { $0.frame.intersects(rect) })
            if let index {
                labels[wid] = "\(index + 1) · \(screens[index].localizedName)"
            }
        }
        return labels
    }

    /// Minimize (or restore, if already minimized) a window from its card,
    /// then refresh the row so the card reflects the new state.
    private func toggleMinimizeFromPreview(_ item: WindowPreviewItem, app: NSRunningApplication, dockItem: DockItem) {
        windowTracker.setLastActiveWindow(item.element, for: app)
        windowTracker.suppressFocusTracking(for: app)
        let handled = item.isMinimized
            ? windowTracker.focusWindow(item.element, app: app)
            : windowTracker.minimizeWindow(item.element)
        guard handled else {
            NSSound.beep()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.showPreview(for: dockItem)
        }
    }

    /// "Keep only this": minimize every other standard window of the app,
    /// then bring the chosen one forward (restoring it if needed) and pin it
    /// as the Dock-click target. Ends the preview like a click does.
    private func keepOnlyWindowFromPreview(_ item: WindowPreviewItem, app: NSRunningApplication) {
        suppressPreviewAfterAction(for: 1.0)
        windowTracker.suppressFocusTracking(for: app, interval: 1.5)
        for window in windowTracker.standardWindowsInStableOrder(for: app)
        where !windowTracker.isSameWindow(window, item.element) && !windowTracker.isMinimized(window) {
            windowTracker.minimizeWindow(window)
        }
        windowTracker.setLastActiveWindow(item.element, for: app)
        if !windowTracker.focusWindow(item.element, app: app) {
            NSSound.beep()
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
            let remaining = self.windowTracker.standardWindowsInInteractionOrder(for: app)
            if remaining.count >= self.minimumPreviewWindowCount {
                self.showPreview(for: dockItem)
            } else {
                self.dismissPreview()
            }
        }
    }
}
