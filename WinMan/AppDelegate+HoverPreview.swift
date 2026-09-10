import Cocoa
import CoreGraphics

// Hover state machine and preview panel orchestration. Decisions come from
// HoverPolicy; this file owns the timers and panel side effects.
extension AppDelegate {

    func dismissPreview(reason: String = "unspecified") {
        if previewPanel?.isVisible == true {
            WinManLog.app.debug("[hover] dismiss (\(reason, privacy: .public))")
        }
        previewPanel?.dismiss()
        previewDockItem = nil
        previewItems = []
        previewApp = nil
    }

    /// Bring one card's window forward — shared by clicking a card and the
    /// 1–9 hotkeys. Single-view: only that window comes up, and it becomes
    /// the Dock-click target.
    func selectPreviewWindow(_ element: AXUIElement, app: NSRunningApplication) {
        dismissPreview(reason: "select")
        windowTracker.setLastActiveWindow(element, for: app)
        windowTracker.suppressFocusTracking(for: app)
        if !windowTracker.focusWindow(element, app: app) {
            NSSound.beep()
        }
    }

    /// Hotkey: digit N picks the N-th card of the visible row.
    @discardableResult
    func selectPreviewItem(number: Int) -> Bool {
        guard previewPanel?.isVisible == true,
              let app = previewApp,
              number >= 1, number <= previewItems.count else { return false }
        let item = previewItems[number - 1]
        WinManLog.app.debug("[hotkey] \(number) → \(item.title, privacy: .public)")
        suppressPreviewAfterAction(for: 1.0)
        selectPreviewWindow(item.element, app: app)
        return true
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
        dismissPreview(reason: "suppressPreviewAfterAction")
    }

    static func handleMouseMoved(location: CGPoint, delegate: AppDelegate) {
        delegate.dockMonitor.refreshIfNeeded(near: location)

        let hitItem = delegate.dockMonitor.items.first(where: { $0.rect.contains(location) })
        delegate.updatePointerHeading(location)
        let rowFrame = delegate.previewPanel.flatMap { $0.isVisible ? $0.frame : nil }
        let hitUnderRow = hitItem.flatMap { item in rowFrame.map { $0.minX...$0.maxX ~= item.rect.midX } } ?? false
        // Only a pointer that is actually heading into the row gets the
        // fly-over allowance; sliding sideways along the Dock means leaving.
        let flyingOver = hitUnderRow && delegate.isPointerHeadingIntoRow()
        let response = HoverPolicy.response(
            hitItemIdentity: hitItem?.identity,
            hitItemIsManaged: hitItem.map(delegate.isManaged) ?? false,
            hitItemIsUnderPanel: flyingOver,
            hoveredIdentity: delegate.hoveredDockItem?.identity,
            isOverPanel: delegate.isLocationOverPanel(location),
            isSuppressed: Date() < delegate.suppressPreviewUntil
        )

        if let panel = delegate.previewPanel, panel.isVisible {
            WinManLog.app.debug("[hover] \(String(describing: response), privacy: .public) at (\(Int(location.x)),\(Int(location.y))) hit=\(hitItem?.name ?? "-", privacy: .public) hovered=\(delegate.hoveredDockItem?.name ?? "-", privacy: .public) fly=\(flyingOver) heading=(\(Int(delegate.pointerHeading.dx)),\(Int(delegate.pointerHeading.dy))) panel=\(NSStringFromRect(panel.frame), privacy: .public)")
        }

        switch response {
        case .suppressed:
            // Cancel any hover timer that might be running, but don't start a
            // new one. Also forget the hovered item: when the pointer comes
            // back after the suppression window it must count as *entering*
            // the icon (beginHover), not as still sitting on it — otherwise a
            // quick leave-and-return after a Dock click never shows a preview.
            delegate.hoverTimer?.invalidate()
            delegate.hoverTimer = nil
            delegate.hoveredDockItem = nil

        case .beginHover:
            // Moved to a different dock item — restart the hover timer. The
            // current row (if any) stays up until the new one is ready, so a
            // pointer that merely brushes another icon on its way into the
            // row never tears it down.
            guard let dockItem = hitItem else { return }
            let panelVisible = delegate.previewPanel?.isVisible == true
            // Like the Windows taskbar: once a preview is up, sliding to the
            // next icon switches previews quickly. An icon that sits *under*
            // the current row is a likely fly-over, so it needs a real pause.
            let delay: TimeInterval
            if !panelVisible {
                delay = delegate.hoverDelay
            } else if let frame = delegate.previewPanel?.frame, frame.minX...frame.maxX ~= dockItem.rect.midX {
                delay = 0.3
            } else {
                delay = 0.08
            }
            delegate.dismissPreviewTimer?.invalidate()
            delegate.dismissPreviewTimer = nil
            delegate.hoverTimer?.invalidate()
            delegate.hoveredDockItem = dockItem

            delegate.hoverTimer = Timer.scheduledTimer(
                withTimeInterval: delay,
                repeats: false
            ) { [weak delegate] _ in
                guard let delegate = delegate else { return }
                DispatchQueue.main.async { delegate.showPreview(for: dockItem) }
            }

        case .stayOnItem:
            // Keep the panel alive — cancel any pending dismiss
            delegate.dismissPreviewTimer?.invalidate()
            delegate.dismissPreviewTimer = nil

        case .stayOnPanel:
            // Inside the row: cancel any pending dismiss, and cancel a switch
            // to another icon the pointer brushed on the way in.
            delegate.dismissPreviewTimer?.invalidate()
            delegate.dismissPreviewTimer = nil
            if let anchor = delegate.previewDockItem,
               delegate.hoveredDockItem?.identity != anchor.identity {
                delegate.hoverTimer?.invalidate()
                delegate.hoverTimer = nil
                delegate.hoveredDockItem = anchor
            }

        case .leftHoverArea:
            delegate.hoverTimer?.invalidate()
            delegate.hoverTimer = nil
            // While a preview is still being built, keep the hovered item: the
            // pointer is usually already heading to where the panel will
            // appear, and clearing it here would cancel the show.
            if delegate.previewPending == nil {
                delegate.hoveredDockItem = nil
            }

            if delegate.previewPanel?.isVisible == true, delegate.dismissPreviewTimer == nil {
                // Leaving onto another Dock icon is deliberate — close fast.
                // Leaving upward/outward may be an overshoot — allow a return.
                let grace: TimeInterval = hitItem != nil ? 0.2 : 0.4
                delegate.dismissPreviewTimer = Timer.scheduledTimer(
                    withTimeInterval: grace,
                    repeats: false
                ) { [weak delegate] _ in
                    DispatchQueue.main.async { delegate?.dismissPreview(reason: "leftHoverArea timer") }
                    delegate?.dismissPreviewTimer = nil
                }
            }
        }
    }

    /// Exponential moving average of the pointer's motion so a single jittery
    /// sample cannot flip the "heading into the row" decision.
    func updatePointerHeading(_ location: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        defer { lastPointerLocation = location; lastPointerTime = now }
        guard let previous = lastPointerLocation else { return }
        let step = CGVector(dx: location.x - previous.x, dy: location.y - previous.y)
        // After a pause, or a teleport-sized jump, the next movement is a new
        // gesture: start from its own first sample instead of stale momentum.
        if now - lastPointerTime > 0.12 || abs(step.dx) + abs(step.dy) > 400 {
            pointerHeading = step
            return
        }
        pointerHeading = CGVector(
            dx: pointerHeading.dx * 0.5 + step.dx * 0.5,
            dy: pointerHeading.dy * 0.5 + step.dy * 0.5
        )
    }

    /// True when the smoothed heading has a real component toward the row
    /// (cosine ≥ 0.2, about 12° above the Dock — a far card in a wide row is
    /// reached at a shallow angle), i.e. the pointer is climbing into the row
    /// rather than traveling along the Dock.
    func isPointerHeadingIntoRow() -> Bool {
        guard let panel = previewPanel, panel.isVisible,
              let anchor = previewDockItem ?? hoveredDockItem,
              let primary = NSScreen.screens.first?.frame else { return false }
        // Panel frame back to Quartz coordinates (the conversion is its own inverse).
        let rowQuartz = ScreenGeometry.appKitRect(fromQuartz: panel.frame, primaryScreenFrame: primary)
        let heading = pointerHeading
        let speed = (heading.dx * heading.dx + heading.dy * heading.dy).squareRoot()
        guard speed > 0.5 else { return false }
        // "Into the row" is the direction perpendicular to the Dock edge the
        // row hangs off (bottom Dock: up), never the diagonal toward the row's
        // center — a wide row's center is far to the side, which would make
        // plain sideways sliding look like an approach.
        let intoRow: CGVector
        if rowQuartz.maxY <= anchor.rect.minY {
            intoRow = CGVector(dx: 0, dy: -1)       // row above the Dock (Quartz y grows downward)
        } else if rowQuartz.minY >= anchor.rect.maxY {
            intoRow = CGVector(dx: 0, dy: 1)        // row below (top Dock)
        } else if rowQuartz.minX >= anchor.rect.maxX {
            intoRow = CGVector(dx: 1, dy: 0)        // row to the right (left Dock)
        } else {
            intoRow = CGVector(dx: -1, dy: 0)       // row to the left (right Dock)
        }
        let cosine = (heading.dx * intoRow.dx + heading.dy * intoRow.dy) / speed
        return cosine >= 0.2
    }

    func isLocationOverPanel(_ location: CGPoint) -> Bool {
        // Anchored on the item the row was shown for, not on the transient
        // hovered item, so brushing another icon cannot make a pointer that is
        // physically inside the row count as "outside".
        guard let panel = previewPanel,
              panel.isVisible,
              let dockItem = previewDockItem ?? hoveredDockItem,
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

        // Main-thread-only reads, captured before going to the background.
        let tracker = windowTracker
        let lastActive = tracker.lastActiveWindow(for: app)
        let minimum = minimumPreviewWindowCount
        let canCapture = CGPreflightScreenCaptureAccess()
        let screens = NSScreen.screens.map { screen -> (frame: CGRect, name: String, isBuiltin: Bool) in
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) }
            return (screen.frame, screen.localizedName, displayID.map { CGDisplayIsBuiltin($0) != 0 } ?? false)
        }
        previewPending = dockItem

        // Every AX round trip runs off the main thread. After the Mac has sat
        // idle the target app is often napping and each call can take the
        // full 0.25s messaging timeout; doing that on main would stall the
        // event tap and drop the mouse events that keep the preview alive.
        previewBuildQueue.async { [weak self] in
            // Fixed order (creation order) so cards never shuffle; the
            // last-active window — what a Dock click toggles — is flagged.
            let axWindows = tracker.standardWindowsInStableOrder(for: app)
            guard axWindows.count >= minimum else {
                DispatchQueue.main.async { self?.finishPendingPreview(dockItem) }
                return
            }
            let lastActiveInList = lastActive.flatMap { last in
                axWindows.first { tracker.isSameWindow($0, last) }
            }
            let screenLabels = Self.screenLabelsByWindowID(for: app, screens: screens)

            var items: [WindowPreviewItem] = []
            for (position, axWindow) in axWindows.enumerated() {
                let title = tracker.windowTitle(axWindow) ?? ""
                let wid = tracker.windowID(axWindow)
                let minimized = tracker.isMinimized(axWindow)

                let itemID: String
                if let wid {
                    itemID = "cg:\(wid)"
                } else {
                    let pointer = Unmanaged.passUnretained(axWindow).toOpaque()
                    itemID = "ax:\(UInt(bitPattern: pointer))"
                }
                var item = WindowPreviewItem(
                    id: itemID, element: axWindow, title: title,
                    thumbnail: nil, isMinimized: minimized, windowID: wid,
                    isLastActive: lastActiveInList.map { tracker.isSameWindow($0, axWindow) } ?? false,
                    screenLabel: wid.flatMap { screenLabels[$0] },
                    index: position + 1
                )
                if canCapture, !minimized, let wid {
                    item.thumbnail = captureWindowThumbnail(
                        windowID: wid,
                        targetSize: CGSize(width: 156, height: 116)
                    )
                }
                items.append(item)
            }

            DispatchQueue.main.async {
                guard let self else { return }
                self.finishPendingPreview(dockItem)
                // The pointer may have moved on while the row was built.
                guard self.isPreviewEnabled,
                      self.hoveredDockItem?.identity == dockItem.identity,
                      Date() >= self.suppressPreviewUntil else { return }

                if self.previewPanel == nil { self.previewPanel = PreviewPanel() }
                self.previewDockItem = dockItem
                self.previewItems = items
                self.previewApp = app

                self.previewPanel?.show(
                    for: app, windows: items, nearDockRect: dockItem.rect,
                    onSelect: { [weak self] element, app in
                        self?.selectPreviewWindow(element, app: app)
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

    private func finishPendingPreview(_ dockItem: DockItem) {
        if previewPending?.identity == dockItem.identity {
            previewPending = nil
        }
    }

    /// Display name per window for windows on a *secondary* display; the
    /// built-in screen is the default and gets no label. Uses the window's
    /// last known bounds so minimized windows are labeled too.
    private static func screenLabelsByWindowID(
        for app: NSRunningApplication,
        screens: [(frame: CGRect, name: String, isBuiltin: Bool)]
    ) -> [CGWindowID: String] {
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
            if let index, !screens[index].isBuiltin {
                labels[wid] = screens[index].name
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
