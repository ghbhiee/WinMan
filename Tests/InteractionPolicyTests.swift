import Foundation

enum InteractionPolicyTests {
    static func run() {
        testDockClickPolicy()
        testHoverPolicy()
        print("InteractionPolicyTests passed")
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
            hitItemIdentity: "a", hoveredIdentity: nil,
            isOverPanel: false, isSuppressed: true
        ) == .suppressed)

        // Entering a new dock item starts a hover cycle
        check(HoverPolicy.response(
            hitItemIdentity: "a", hoveredIdentity: nil,
            isOverPanel: false, isSuppressed: false
        ) == .beginHover)

        // Moving between different dock items restarts the cycle
        check(HoverPolicy.response(
            hitItemIdentity: "b", hoveredIdentity: "a",
            isOverPanel: false, isSuppressed: false
        ) == .beginHover)

        // Staying on the same item keeps the panel alive
        check(HoverPolicy.response(
            hitItemIdentity: "a", hoveredIdentity: "a",
            isOverPanel: false, isSuppressed: false
        ) == .stayOnItem)

        // Moving onto the panel (or its corridor) keeps it alive
        check(HoverPolicy.response(
            hitItemIdentity: nil, hoveredIdentity: "a",
            isOverPanel: true, isSuppressed: false
        ) == .stayOnPanel)

        // Leaving both dock and panel schedules dismissal
        check(HoverPolicy.response(
            hitItemIdentity: nil, hoveredIdentity: "a",
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
