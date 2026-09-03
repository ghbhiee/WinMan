import Cocoa
import CoreGraphics

// Hover state machine and preview panel orchestration. Decisions come from
// HoverPolicy; this file owns the timers and panel side effects.
extension AppDelegate {

    /// After a click or right-click action, hover preview is suppressed for a
    /// short time. Time-based suppression never gets permanently stuck unlike
    /// an exit-gate boolean.
    func suppressPreviewAfterAction(for interval: TimeInterval) {
        suppressPreviewUntil = Date().addingTimeInterval(interval)
        hoverTimer?.invalidate()
        hoverTimer = nil
        dismissPreviewTimer?.invalidate()
        dismissPreviewTimer = nil
        previewPanel?.dismiss()
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
            delegate.previewPanel?.dismiss()
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
        guard isPreviewEnabled, isManaged(dockItem) else { return }

        let apps = NSWorkspace.shared.runningApplications
        guard let app = apps.first(where: { self.matches(app: $0, dockItem: dockItem) }) else { return }

        // Put the tracked active window first, then fall back to system Z-order.
        let axWindows = windowTracker.standardWindowsInInteractionOrder(for: app)
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
                        guard let self else { return }
                        self.previewPanel?.dismiss()
                        // Single-view: bring up only the chosen window and pin it.
                        self.windowTracker.setLastActiveWindow(element, for: app)
                        self.windowTracker.suppressFocusTracking(for: app)
                        if !self.windowTracker.focusWindow(element, app: app) {
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
            let remaining = self.windowTracker.standardWindowsInInteractionOrder(for: app)
            if remaining.count >= self.minimumPreviewWindowCount {
                self.showPreview(for: dockItem)
            } else {
                self.previewPanel?.dismiss()
            }
        }
    }
}
