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

// MARK: - Single-view mode click (allowlisted apps)

enum ManagedClickAction: Equatable {
    /// The target window is up front and focused — minimize it.
    case minimize
    /// The target window is minimized — bring it back (only it).
    case restore
    /// The target window is visible but not the focused one — focus only it.
    case focus
    /// Nothing to act on; let macOS handle the Dock click.
    case passThrough
}

/// Windows-taskbar semantics for one app's "current view": the Dock icon
/// always toggles the window WinMan last acted on, regardless of which
/// sibling macOS happened to focus afterwards.
enum ManagedClickPolicy {
    static func action(
        hasTarget: Bool,
        targetIsMinimized: Bool,
        targetIsFullscreen: Bool,
        targetIsFocused: Bool,
        isFrontmost: Bool,
        isAppHidden: Bool
    ) -> ManagedClickAction {
        guard hasTarget else { return .passThrough }
        if targetIsFullscreen { return .passThrough }
        if targetIsMinimized { return .restore }
        if isFrontmost && !isAppHidden && targetIsFocused { return .minimize }
        return .focus
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
    /// `hitItemIsManaged`: previews exist only for allowlisted apps. Hovering a
    /// non-managed dock item behaves like leaving the hover area entirely, so
    /// other apps never see a panel or a timer.
    /// `hitItemIsUnderPanel`: the icon sits below the visible row *and* the
    /// pointer is heading into the row (caller decides from its motion). Such a
    /// fly-over toward a far card must not tear the row down; a pointer merely
    /// sliding along the Dock does not qualify and counts as leaving.
    static func response(
        hitItemIdentity: String?,
        hitItemIsManaged: Bool,
        hitItemIsUnderPanel: Bool = false,
        hoveredIdentity: String?,
        isOverPanel: Bool,
        isSuppressed: Bool
    ) -> HoverResponse {
        if isSuppressed { return .suppressed }
        if let hitItemIdentity {
            guard hitItemIsManaged else {
                return hitItemIsUnderPanel ? .stayOnPanel : .leftHoverArea
            }
            return hitItemIdentity == hoveredIdentity ? .stayOnItem : .beginHover
        }
        return isOverPanel ? .stayOnPanel : .leftHoverArea
    }
}

// MARK: - Option-Tab window switcher

enum SwitcherPolicy {
    /// Selection when the switcher opens: the *next* window, so a quick
    /// Option-Tab tap flips to the previous window like Windows Alt-Tab.
    static func initialIndex(count: Int, reversed: Bool) -> Int {
        guard count > 1 else { return 0 }
        return reversed ? count - 1 : 1
    }

    static func nextIndex(from index: Int, count: Int, reversed: Bool) -> Int {
        guard count > 0 else { return 0 }
        return reversed ? (index - 1 + count) % count : (index + 1) % count
    }
}

// MARK: - Versions

enum SemanticVersion {
    /// "v1.10.2" → [1, 10, 2]; missing components count as 0.
    static func components(_ version: String) -> [Int] {
        var text = version.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
    }

    /// Negative when `a < b`, zero when equal, positive when `a > b`.
    static func compare(_ a: String, _ b: String) -> Int {
        let lhs = components(a), rhs = components(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}

