import Foundation

enum InteractionPolicyTests {
    static func run() {
        testDockClickPolicy()
        testManagedClickPolicy()
        testHoverPolicy()
        testSwitcherPolicy()
        print("InteractionPolicyTests passed")
    }

    private static func testManagedClickPolicy() {
        // Target up front and focused → minimize
        check(ManagedClickPolicy.action(
            hasTarget: true, targetIsMinimized: false, targetIsFullscreen: false,
            targetIsFocused: true, isFrontmost: true, isAppHidden: false
        ) == .minimize)

        // The core bug: after minimizing A, macOS focused sibling B. The
        // pinned target A is minimized → restore A, not B.
        check(ManagedClickPolicy.action(
            hasTarget: true, targetIsMinimized: true, targetIsFullscreen: false,
            targetIsFocused: false, isFrontmost: true, isAppHidden: false
        ) == .restore)

        // Target visible but another window of the app has focus → focus target only
        check(ManagedClickPolicy.action(
            hasTarget: true, targetIsMinimized: false, targetIsFullscreen: false,
            targetIsFocused: false, isFrontmost: true, isAppHidden: false
        ) == .focus)

        // App in the background with the target visible → focus target only
        check(ManagedClickPolicy.action(
            hasTarget: true, targetIsMinimized: false, targetIsFullscreen: false,
            targetIsFocused: true, isFrontmost: false, isAppHidden: false
        ) == .focus)

        // Hidden app (Cmd-H) → focus (which un-hides), never minimize
        check(ManagedClickPolicy.action(
            hasTarget: true, targetIsMinimized: false, targetIsFullscreen: false,
            targetIsFocused: true, isFrontmost: true, isAppHidden: true
        ) == .focus)

        // No standard window / full-screen target → native Dock behavior
        check(ManagedClickPolicy.action(
            hasTarget: false, targetIsMinimized: false, targetIsFullscreen: false,
            targetIsFocused: false, isFrontmost: false, isAppHidden: false
        ) == .passThrough)
        check(ManagedClickPolicy.action(
            hasTarget: true, targetIsMinimized: false, targetIsFullscreen: true,
            targetIsFocused: true, isFrontmost: true, isAppHidden: false
        ) == .passThrough)
    }

    private static func testSwitcherPolicy() {
        // Opening selects the *next* window so a quick tap flips windows
        check(SwitcherPolicy.initialIndex(count: 5, reversed: false) == 1)
        check(SwitcherPolicy.initialIndex(count: 5, reversed: true) == 4)
        check(SwitcherPolicy.initialIndex(count: 1, reversed: false) == 0)
        check(SwitcherPolicy.initialIndex(count: 0, reversed: false) == 0)

        // Cycling wraps in both directions
        check(SwitcherPolicy.nextIndex(from: 1, count: 3, reversed: false) == 2)
        check(SwitcherPolicy.nextIndex(from: 2, count: 3, reversed: false) == 0)
        check(SwitcherPolicy.nextIndex(from: 0, count: 3, reversed: true) == 2)
        check(SwitcherPolicy.nextIndex(from: 2, count: 3, reversed: true) == 1)
        check(SwitcherPolicy.nextIndex(from: 0, count: 0, reversed: false) == 0)
    }

    private static func testDockClickPolicy() {
        // Frontmost app with a visible window → minimize (the core toggle)
        check(DockClickPolicy.action(
            isFrontmost: true, isAppHidden: false, hasWindow: true,
            windowIsMinimized: false, windowIsFullscreen: false
        ) == .minimize)

        // Second click: window now minimized → restore
        check(DockClickPolicy.action(
            isFrontmost: true, isAppHidden: false, hasWindow: true,
            windowIsMinimized: true, windowIsFullscreen: false
        ) == .restore)

        // Background app → restore/raise
        check(DockClickPolicy.action(
            isFrontmost: false, isAppHidden: false, hasWindow: true,
            windowIsMinimized: false, windowIsFullscreen: false
        ) == .restore)

        // Hidden app (Cmd-H) → restore even though it is "frontmost=false"
        check(DockClickPolicy.action(
            isFrontmost: true, isAppHidden: true, hasWindow: true,
            windowIsMinimized: false, windowIsFullscreen: false
        ) == .restore)

        // No window → native Dock behavior (may reopen the app)
        check(DockClickPolicy.action(
            isFrontmost: false, isAppHidden: false, hasWindow: false,
            windowIsMinimized: false, windowIsFullscreen: false
        ) == .passThrough)

        // Full-screen window → native Dock behavior
        check(DockClickPolicy.action(
            isFrontmost: true, isAppHidden: false, hasWindow: true,
            windowIsMinimized: false, windowIsFullscreen: true
        ) == .passThrough)
    }

    private static func testHoverPolicy() {
        // Suppression wins over everything
        check(HoverPolicy.response(
            hitItemIdentity: "a", hitItemIsManaged: true, hoveredIdentity: nil,
            isOverPanel: false, isSuppressed: true
        ) == .suppressed)

        // Entering a new dock item starts a hover cycle
        check(HoverPolicy.response(
            hitItemIdentity: "a", hitItemIsManaged: true, hoveredIdentity: nil,
            isOverPanel: false, isSuppressed: false
        ) == .beginHover)

        // Moving between different dock items restarts the cycle
        check(HoverPolicy.response(
            hitItemIdentity: "b", hitItemIsManaged: true, hoveredIdentity: "a",
            isOverPanel: false, isSuppressed: false
        ) == .beginHover)

        // Staying on the same item keeps the panel alive
        check(HoverPolicy.response(
            hitItemIdentity: "a", hitItemIsManaged: true, hoveredIdentity: "a",
            isOverPanel: false, isSuppressed: false
        ) == .stayOnItem)

        // Moving onto the panel (or its corridor) keeps it alive
        check(HoverPolicy.response(
            hitItemIdentity: nil, hitItemIsManaged: false, hoveredIdentity: "a",
            isOverPanel: true, isSuppressed: false
        ) == .stayOnPanel)

        // Leaving both dock and panel schedules dismissal
        check(HoverPolicy.response(
            hitItemIdentity: nil, hitItemIsManaged: false, hoveredIdentity: "a",
            isOverPanel: false, isSuppressed: false
        ) == .leftHoverArea)

        // Non-allowlisted dock item: no preview cycle, and an open panel for
        // a managed app is dismissed just like leaving the hover area
        check(HoverPolicy.response(
            hitItemIdentity: "other", hitItemIsManaged: false, hoveredIdentity: nil,
            isOverPanel: false, isSuppressed: false
        ) == .leftHoverArea)
        check(HoverPolicy.response(
            hitItemIdentity: "other", hitItemIsManaged: false, hoveredIdentity: "a",
            isOverPanel: false, isSuppressed: false
        ) == .leftHoverArea)
    }

    private static func check(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(condition(), "Expectation failed", file: file, line: line)
    }
}
