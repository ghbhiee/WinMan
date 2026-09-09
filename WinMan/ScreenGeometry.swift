import Cocoa

enum DockEdge {
    case bottom
    case top
    case left
    case right
}

enum ScreenGeometry {
    static func appKitPoint(fromQuartz point: CGPoint, primaryScreenFrame: CGRect) -> CGPoint {
        CGPoint(x: point.x, y: primaryScreenFrame.maxY - point.y)
    }

    static func appKitRect(fromQuartz rect: CGRect, primaryScreenFrame: CGRect) -> CGRect {
        CGRect(
            x: rect.minX,
            y: primaryScreenFrame.maxY - rect.maxY,
            width: rect.width,
            height: rect.height
        )
    }

    static func screenFrame(containing rect: CGRect, screenFrames: [CGRect]) -> CGRect? {
        guard let first = screenFrames.first else { return nil }

        return screenFrames.max { lhs, rhs in
            intersectionArea(lhs, rect) < intersectionArea(rhs, rect)
        } ?? first
    }

    static func dockEdge(for dockRect: CGRect, in screenFrame: CGRect) -> DockEdge {
        let distances: [(DockEdge, CGFloat)] = [
            (.bottom, abs(dockRect.minY - screenFrame.minY)),
            (.top, abs(screenFrame.maxY - dockRect.maxY)),
            (.left, abs(dockRect.minX - screenFrame.minX)),
            (.right, abs(screenFrame.maxX - dockRect.maxX)),
        ]
        return distances.min(by: { $0.1 < $1.1 })?.0 ?? .bottom
    }

    /// Width that exactly fits the card row: 176pt cards (160pt thumbnail +
    /// 8pt card padding each side), 10pt spacing, 10pt horizontal padding on
    /// each side — clamped to the screen so every card that fits is visible
    /// without scrolling.
    static func previewPanelWidth(windowCount: Int, screenWidth: CGFloat) -> CGFloat {
        let contentWidth = CGFloat(windowCount) * 176
            + CGFloat(max(0, windowCount - 1)) * 10
            + 20
        return min(contentWidth, max(200, screenWidth - 16))
    }

    static func previewFrame(
        panelSize: CGSize,
        dockRect: CGRect,
        screenFrame: CGRect,
        gap: CGFloat = 8
    ) -> CGRect {
        let edge = dockEdge(for: dockRect, in: screenFrame)
        let desiredOrigin: CGPoint

        switch edge {
        case .bottom:
            desiredOrigin = CGPoint(
                x: dockRect.midX - panelSize.width / 2,
                y: dockRect.maxY + gap
            )
        case .top:
            desiredOrigin = CGPoint(
                x: dockRect.midX - panelSize.width / 2,
                y: dockRect.minY - panelSize.height - gap
            )
        case .left:
            desiredOrigin = CGPoint(
                x: dockRect.maxX + gap,
                y: dockRect.midY - panelSize.height / 2
            )
        case .right:
            desiredOrigin = CGPoint(
                x: dockRect.minX - panelSize.width - gap,
                y: dockRect.midY - panelSize.height / 2
            )
        }

        let minimumX = screenFrame.minX + gap
        let maximumX = max(minimumX, screenFrame.maxX - panelSize.width - gap)
        let minimumY = screenFrame.minY + gap
        let maximumY = max(minimumY, screenFrame.maxY - panelSize.height - gap)

        return CGRect(
            x: min(max(desiredOrigin.x, minimumX), maximumX),
            y: min(max(desiredOrigin.y, minimumY), maximumY),
            width: panelSize.width,
            height: panelSize.height
        )
    }

    static func containsPreviewPath(
        _ point: CGPoint,
        dockRect: CGRect,
        panelRect: CGRect,
        panelMargin: CGFloat = 52,
        dockMargin: CGFloat = 150,
        axisMargin: CGFloat = 18
    ) -> Bool {
        if panelRect.insetBy(dx: -32, dy: -28).contains(point) {
            return true
        }

        if dockRect.minY >= panelRect.maxY {
            return pointInVerticalBridge(
                point,
                topY: panelRect.maxY,
                bottomY: dockRect.minY,
                topMinX: panelRect.minX - panelMargin,
                topMaxX: panelRect.maxX + panelMargin,
                bottomMinX: dockRect.minX - dockMargin,
                bottomMaxX: dockRect.maxX + dockMargin,
                axisMargin: axisMargin
            )
        }

        if panelRect.minY >= dockRect.maxY {
            return pointInVerticalBridge(
                point,
                topY: dockRect.maxY,
                bottomY: panelRect.minY,
                topMinX: dockRect.minX - dockMargin,
                topMaxX: dockRect.maxX + dockMargin,
                bottomMinX: panelRect.minX - panelMargin,
                bottomMaxX: panelRect.maxX + panelMargin,
                axisMargin: axisMargin
            )
        }

        if panelRect.minX >= dockRect.maxX {
            return pointInHorizontalBridge(
                point,
                leftX: dockRect.maxX,
                rightX: panelRect.minX,
                leftMinY: dockRect.minY - dockMargin,
                leftMaxY: dockRect.maxY + dockMargin,
                rightMinY: panelRect.minY - panelMargin,
                rightMaxY: panelRect.maxY + panelMargin,
                axisMargin: axisMargin
            )
        }

        if dockRect.minX >= panelRect.maxX {
            return pointInHorizontalBridge(
                point,
                leftX: panelRect.maxX,
                rightX: dockRect.minX,
                leftMinY: panelRect.minY - panelMargin,
                leftMaxY: panelRect.maxY + panelMargin,
                rightMinY: dockRect.minY - dockMargin,
                rightMaxY: dockRect.maxY + dockMargin,
                axisMargin: axisMargin
            )
        }

        return false
    }

    private static func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private static func pointInVerticalBridge(
        _ point: CGPoint,
        topY: CGFloat,
        bottomY: CGFloat,
        topMinX: CGFloat,
        topMaxX: CGFloat,
        bottomMinX: CGFloat,
        bottomMaxX: CGFloat,
        axisMargin: CGFloat
    ) -> Bool {
        guard point.y >= topY - axisMargin, point.y <= bottomY + axisMargin else { return false }
        let progress = max(0, min(1, (point.y - topY) / max(bottomY - topY, 1)))
        let minX = topMinX + (bottomMinX - topMinX) * progress
        let maxX = topMaxX + (bottomMaxX - topMaxX) * progress
        return point.x >= minX && point.x <= maxX
    }

    private static func pointInHorizontalBridge(
        _ point: CGPoint,
        leftX: CGFloat,
        rightX: CGFloat,
        leftMinY: CGFloat,
        leftMaxY: CGFloat,
        rightMinY: CGFloat,
        rightMaxY: CGFloat,
        axisMargin: CGFloat
    ) -> Bool {
        guard point.x >= leftX - axisMargin, point.x <= rightX + axisMargin else { return false }
        let progress = max(0, min(1, (point.x - leftX) / max(rightX - leftX, 1)))
        let minY = leftMinY + (rightMinY - leftMinY) * progress
        let maxY = leftMaxY + (rightMaxY - leftMaxY) * progress
        return point.y >= minY && point.y <= maxY
    }
}
