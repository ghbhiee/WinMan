import Cocoa

@main
struct ScreenGeometryTests {
    static func main() {
        testQuartzConversion()
        testScreenSelection()
        testPreviewPlacement()
        testPreviewBridge()
        print("ScreenGeometryTests passed")
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

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        precondition(condition(), "Expectation failed", file: file, line: line)
    }
}
