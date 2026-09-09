import Cocoa

@main
struct ScreenGeometryTests {
    static func main() {
        testQuartzConversion()
        testScreenSelection()
        testPreviewPlacement()
        testPreviewBridge()
        testDockEdge()
        testPanelWidth()
        testPlacementClamping()
        print("ScreenGeometryTests passed")
        InteractionPolicyTests.run()
    }

    private static func testQuartzConversion() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let quartzDock = CGRect(x: 500, y: 1016, width: 64, height: 64)
        let appKitDock = ScreenGeometry.appKitRect(
            fromQuartz: quartzDock,
            primaryScreenFrame: primary
        )

        expect(appKitDock == CGRect(x: 500, y: 0, width: 64, height: 64))
        expect(ScreenGeometry.appKitPoint(
            fromQuartz: CGPoint(x: -100, y: -50),
            primaryScreenFrame: primary
        ) == CGPoint(x: -100, y: 1130))
    }

    private static func testScreenSelection() {
        let primary = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let secondary = CGRect(x: -1280, y: 0, width: 1280, height: 1024)
        let dock = CGRect(x: -1280, y: 300, width: 64, height: 64)

        expect(ScreenGeometry.screenFrame(
            containing: dock,
            screenFrames: [primary, secondary]
        ) == secondary)
    }

    private static func testPreviewPlacement() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let panelSize = CGSize(width: 400, height: 200)

        let bottom = ScreenGeometry.previewFrame(
            panelSize: panelSize,
            dockRect: CGRect(x: 500, y: 0, width: 64, height: 64),
            screenFrame: screen
        )
        expect(bottom.origin == CGPoint(x: 332, y: 72))

        let top = ScreenGeometry.previewFrame(
            panelSize: panelSize,
            dockRect: CGRect(x: 500, y: 1016, width: 64, height: 64),
            screenFrame: screen
        )
        expect(top.origin == CGPoint(x: 332, y: 808))

        let left = ScreenGeometry.previewFrame(
            panelSize: panelSize,
            dockRect: CGRect(x: 0, y: 400, width: 64, height: 64),
            screenFrame: screen
        )
        expect(left.origin == CGPoint(x: 72, y: 332))
    }

    private static func testPreviewBridge() {
        let dock = CGRect(x: 500, y: 0, width: 64, height: 64)
        let panel = CGRect(x: 332, y: 72, width: 400, height: 200)

        expect(ScreenGeometry.containsPreviewPath(
            CGPoint(x: 700, y: 68),
            dockRect: dock,
            panelRect: panel
        ))
        expect(!ScreenGeometry.containsPreviewPath(
            CGPoint(x: 1000, y: 68),
            dockRect: dock,
            panelRect: panel
        ))
    }

    private static func testDockEdge() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        expect(ScreenGeometry.dockEdge(
            for: CGRect(x: 500, y: 0, width: 64, height: 64), in: screen
        ) == .bottom)
        expect(ScreenGeometry.dockEdge(
            for: CGRect(x: 1856, y: 400, width: 64, height: 64), in: screen
        ) == .right)
        expect(ScreenGeometry.dockEdge(
            for: CGRect(x: 0, y: 400, width: 64, height: 64), in: screen
        ) == .left)
    }

    private static func testPanelWidth() {
        // 2 windows: 2*176 + 10 spacing + 20 padding
        expect(ScreenGeometry.previewPanelWidth(windowCount: 2, screenWidth: 1920) == 382)
        // 10 windows fit on a wide screen without scrolling
        expect(ScreenGeometry.previewPanelWidth(windowCount: 10, screenWidth: 1920) == 1870)
        // …but never wider than the screen minus margin
        expect(ScreenGeometry.previewPanelWidth(windowCount: 20, screenWidth: 1920) == 1904)
        // Narrow screen clamps to screen width minus margin
        expect(ScreenGeometry.previewPanelWidth(windowCount: 4, screenWidth: 640) == 624)
    }

    private static func testPlacementClamping() {
        let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let panelSize = CGSize(width: 400, height: 200)

        // Dock item at the far left corner — panel must stay on screen
        let frame = ScreenGeometry.previewFrame(
            panelSize: panelSize,
            dockRect: CGRect(x: 0, y: 0, width: 64, height: 64),
            screenFrame: screen
        )
        expect(screen.contains(frame))
        expect(frame.origin.x >= screen.minX)
    }

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(condition(), "Expectation failed", file: file, line: line)
    }
}
