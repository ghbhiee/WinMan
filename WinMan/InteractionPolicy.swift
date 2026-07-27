import Foundation

// Pure decision logic for Dock interactions. No AppKit, no Accessibility, no
// side effects — the event handlers gather the facts, these functions decide,
// and the handlers perform the resulting actions. Fully unit-tested.

// MARK: - Dock click

enum DockClickAction: Equatable {
    /// Minimize the app's current window.
    case minimize
    /// Restore/raise the app's last-active or minimized window.
    case restore
    /// Do nothing and let macOS handle the Dock click natively.
    case passThrough
}

enum DockClickPolicy {
    static func action(
        isFrontmost: Bool,
        isAppHidden: Bool,
        hasWindow: Bool,
        windowIsMinimized: Bool,
        windowIsFullscreen: Bool
    ) -> DockClickAction {
        // No window to act on: the native click may reopen the app.
        guard hasWindow else { return .passThrough }
        // Full-screen windows keep native Dock behavior.
        if windowIsFullscreen { return .passThrough }
        return (isFrontmost && !isAppHidden && !windowIsMinimized) ? .minimize : .restore
    }
}

// MARK: - Hover preview

enum HoverResponse: Equatable {
    /// Recently clicked — cancel any pending hover, start nothing.
    case suppressed
    /// Pointer entered a different dock item — restart the hover cycle for it.
    case beginHover
    /// Pointer is still on the same dock item — keep the panel alive.
    case stayOnItem
    /// Pointer is over the preview panel (or the corridor to it) — keep it alive.
    case stayOnPanel
    /// Pointer left the Dock and the panel — schedule the panel's dismissal.
    case leftHoverArea
}

enum HoverPolicy {
    static func response(
        hitItemIdentity: String?,
        hoveredIdentity: String?,
        isOverPanel: Bool,
        isSuppressed: Bool
    ) -> HoverResponse {
        if isSuppressed { return .suppressed }
        if let hitItemIdentity {
            return hitItemIdentity == hoveredIdentity ? .stayOnItem : .beginHover
        }
        return isOverPanel ? .stayOnPanel : .leftHoverArea
    }
}
