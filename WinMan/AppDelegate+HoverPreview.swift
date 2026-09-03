import Cocoa
import CoreGraphics

/// Aero-Peek bookkeeping: what was brought forward for a hovered thumbnail
/// and what to put back if the user does not click it.
struct PeekState {
    let item: WindowPreviewItem
    let app: NSRunningApplication
    /// False when the card was hovered but nothing was brought forward
    /// (minimized windows are never un-minimized by a peek — that would
    /// play the genie animation twice; they only come back on click).
    let didFocus: Bool
    /// The window that was frontmost before the first peek in this hover
    /// session (kept across thumbnail-to-thumbnail switches).
    let previousFront: (pid: pid_t, wid: CGWindowID)?
}

// Hover state machine and preview panel orchestration. Decisions come from
// HoverPolicy; this file owns the timers and panel side effects.
extension AppDelegate {

    /// Hide the preview. `restorePeek` puts a peeked window back to where it
    /// was; pass false when the user committed (clicked) or acted on the Dock.
    func dismissPreview(restorePeek: Bool = true) {
        endPeek(restore: restorePeek)
        previewPanel?.dismiss()
    }

    // MARK: - Aero Peek

    /// Thumbnail hover in/out. Peeking is debounced so sweeping the pointer
    /// across the row does not thrash windows; leaving is debounced so moving
    /// to the next card switches the peek instead of restoring in between.
    func handleThumbnailHover(_ item: WindowPreviewItem, app: NSRunningApplication, hovering: Bool) {
        if hovering {
            peekRestoreTimer?.invalidate()
            peekRestoreTimer = nil
            peekStartTimer?.invalidate()
            if let peek, peek.item.id == item.id { return }
            peekStartTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.startPeek(item, app: app) }
            }
        } else {
            peekStartTimer?.invalidate()
            peekStartTimer = nil
            guard peek?.item.id == item.id else { return }
            peekRestoreTimer?.invalidate()
            peekRestoreTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: false) { [weak self] _ in
                DispatchQueue.main.async { self?.endPeek(restore: true) }
            }
        }
    }

    private func startPeek(_ item: WindowPreviewItem, app: NSRunningApplication) {
        // Switching cards keeps the original pre-peek front window for the
        // final restore; the first peek of a hover session records it.
        let previousFront = peek?.previousFront ?? frontmostWindowInfo()

        let isMinimized = windowTracker.isMinimized(item.element)
        let alreadyFront = previousFront.map { $0.wid == item.windowID } ?? false
        if isMinimized || alreadyFront {
            // Nothing to bring forward: minimized windows wait for a click,
            // and the front window is already visible.
            peek = PeekState(item: item, app: app, didFocus: false, previousFront: previousFront)
            return
        }

        // Peeking is not a user focus decision: keep last-active tracking quiet.
        windowTracker.suppressFocusTracking(for: app, interval: 2.0)
        if let previousFront, let frontApp = NSRunningApplication(processIdentifier: previousFront.pid) {
            windowTracker.suppressFocusTracking(for: frontApp, interval: 2.0)
        }
        windowTracker.focusWindow(item.element, app: app)
        peek = PeekState(item: item, app: app, didFocus: true, previousFront: previousFront)
        WinManLog.app.debug("[peek] showing \(item.title, privacy: .public)")
    }

    /// End the peek. With `restore`, re-minimize what was minimized and bring
    /// the pre-peek front window back; without it, leave the peeked window up.
    func endPeek(restore: Bool) {
        peekStartTimer?.invalidate()
        peekStartTimer = nil
        peekRestoreTimer?.invalidate()
        peekRestoreTimer = nil
        guard let current = peek else { return }
        peek = nil
        guard restore, current.didFocus else { return }

        if let previous = current.previousFront,
           previous.wid != current.item.windowID,
           let frontApp = NSRunningApplication(processIdentifier: previous.pid),
           let frontWindow = windowTracker.allWindows(for: frontApp).first(where: { windowTracker.windowID($0) == previous.wid }) {
            windowTracker.suppressFocusTracking(for: frontApp, interval: 1.0)
            windowTracker.suppressFocusTracking(for: current.app, interval: 1.0)
            windowTracker.focusWindow(frontWindow, app: frontApp)
        }
        WinManLog.app.debug("[peek] restored \(current.item.title, privacy: .public)")
    }

    private func frontmostWindowInfo() -> (pid: pid_t, wid: CGWindowID)? {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []
        let me = pid_t(ProcessInfo.processInfo.processIdentifier)
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            return (pid, wid)
        }
        return nil
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
        dismissPreview(restorePeek: false)
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
            delegate.dismissPreview(restorePeek: true)
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
                    DispatchQueue.main.async { delegate?.dismissPreview(restorePeek: true) }
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
                isLastActive: lastActive.map { windowTracker.isSameWindow($0, axWindow) } ?? false
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
                        // The click commits whatever the peek already showed.
                        self.dismissPreview(restorePeek: false)
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
                    onHoverWindow: { [weak self] item, hovering in
                        self?.handleThumbnailHover(item, app: app, hovering: hovering)
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
        endPeek(restore: false)
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
                self.dismissPreview(restorePeek: false)
            }
        }
    }
}
