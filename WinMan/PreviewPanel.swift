import Cocoa
import SwiftUI
import CoreGraphics

struct WindowPreviewItem: Identifiable {
    let id: String
    let element: AXUIElement
    let title: String
    var thumbnail: NSImage?
    var isMinimized: Bool
    var windowID: CGWindowID?
    /// The window a Dock click will act on — shown with a blue title.
    var isLastActive: Bool = false
    /// Secondary display name when the window is not on the built-in screen.
    var screenLabel: String? = nil
    /// 1-based position in the row, shown before the title.
    var index: Int = 0
}

/// NSHostingView delivers the first click in a non-key window to the view.
/// Without this, AppKit spends that click on making the panel key and the
/// card's tap gesture never fires — the "click does nothing the first time"
/// bug after the panel has been idle.
private final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

class PreviewPanel: NSPanel {
    private var hostingView: NSHostingView<PreviewPanelView>?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
            styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
            backing: .buffered,
            defer: false
        )
        self.level = .popUpMenu
        self.isOpaque = false
        self.backgroundColor = NSColor.clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        // Never take key status for a click; clicks go straight to the cards.
        self.becomesKeyOnlyIfNeeded = true
    }

    func show(
        for app: NSRunningApplication,
        windows: [WindowPreviewItem],
        nearDockRect dockRect: NSRect,
        onSelect: @escaping (AXUIElement, NSRunningApplication) -> Void,
        onCloseWindow: @escaping (WindowPreviewItem) -> Void,
        onMinimizeWindow: @escaping (WindowPreviewItem) -> Void,
        onMinimizeOthers: @escaping (WindowPreviewItem) -> Void
    ) {
        let screens = NSScreen.screens
        guard let primaryScreenFrame = screens.first?.frame else { return }

        let appKitDockRect = ScreenGeometry.appKitRect(
            fromQuartz: dockRect,
            primaryScreenFrame: primaryScreenFrame
        )
        let screenFrames = screens.map(\.frame)
        guard let screenFrame = ScreenGeometry.screenFrame(
            containing: appKitDockRect,
            screenFrames: screenFrames
        ) else { return }

        let panelWidth = ScreenGeometry.previewPanelWidth(
            windowCount: windows.count,
            screenWidth: screenFrame.width
        )
        // Height hugs the card row so the panel sits right against the Dock
        // and the pointer's trip from icon to card is as short as possible.
        let panelSize = CGSize(width: panelWidth, height: PreviewPanelView.height)
        let frame = ScreenGeometry.previewFrame(
            panelSize: panelSize,
            dockRect: appKitDockRect,
            screenFrame: screenFrame,
            gap: 2
        )
        self.setFrame(frame, display: false)

        let view = PreviewPanelView(
            windows: windows,
            appIcon: app.icon,
            onSelect: { element in onSelect(element, app) },
            onCloseWindow: onCloseWindow,
            onMinimizeWindow: onMinimizeWindow,
            onMinimizeOthers: onMinimizeOthers
        )

        if let hv = hostingView {
            hv.rootView = view
            hv.frame = NSRect(origin: .zero, size: frame.size)
        } else {
            let hv = FirstMouseHostingView(rootView: view)
            hv.frame = NSRect(origin: .zero, size: frame.size)
            self.contentView = hv
            self.hostingView = hv
        }

        self.orderFrontRegardless()
    }

    func dismiss() {
        self.orderOut(nil)
    }
}

// MARK: - SwiftUI views

/// A row of floating window cards — no shared backdrop, no panel chrome.
struct PreviewPanelView: View {
    /// Card (title 14 + 6 + thumbnail 120 + padding 16) plus 10pt row padding.
    static let height: CGFloat = 176

    let windows: [WindowPreviewItem]
    let appIcon: NSImage?
    let onSelect: (AXUIElement) -> Void
    let onCloseWindow: (WindowPreviewItem) -> Void
    let onMinimizeWindow: (WindowPreviewItem) -> Void
    let onMinimizeOthers: (WindowPreviewItem) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(windows) { item in
                    WindowThumbnailView(
                        item: item,
                        appIcon: appIcon,
                        onCloseWindow: { onCloseWindow(item) },
                        onMinimizeWindow: { onMinimizeWindow(item) },
                        onMinimizeOthers: { onMinimizeOthers(item) }
                    )
                    .onTapGesture { onSelect(item.element) }
                }
            }
            .padding(10)
        }
        .frame(height: Self.height)
    }
}

struct WindowThumbnailView: View {
    let item: WindowPreviewItem
    let appIcon: NSImage?
    let onCloseWindow: () -> Void
    let onMinimizeWindow: () -> Void
    let onMinimizeOthers: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 6) {
            // Title row: "N · title" on the left, monochrome controls on the
            // right (hover-revealed). Blue title = last-active window, i.e.
            // what a Dock click toggles.
            HStack(spacing: 4) {
                Text((item.index > 0 ? "\(item.index) · " : "") + (item.title.isEmpty ? "Window" : item.title))
                    .font(.caption.weight(item.isLastActive || isHovered ? .semibold : .regular))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(item.isLastActive ? Color.accentColor : (isHovered ? Color.primary : Color.secondary))
                Spacer(minLength: 0)
                if isHovered {
                    controlButton("rectangle.stack.badge.minus",
                                  help: tr("只留这个窗口（最小化其他）", "Keep only this window (minimize others)"),
                                  action: onMinimizeOthers)
                    controlButton(item.isMinimized ? "arrow.up.right.square" : "minus.square",
                                  help: item.isMinimized ? tr("恢复窗口", "Restore window") : tr("最小化窗口", "Minimize window"),
                                  action: onMinimizeWindow)
                    controlButton("xmark.square",
                                  help: tr("关闭窗口", "Close window"),
                                  action: onCloseWindow)
                }
            }
            .frame(width: 160, height: 16)

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered
                          ? Color.accentColor.opacity(0.18)
                          : Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    .frame(width: 160, height: 120)

                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 156, height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                        .frame(width: 160, height: 120)
                } else if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .opacity(0.45)
                        .frame(width: 160, height: 120)
                }

                // Secondary display the window lives on (built-in shows nothing)
                if let label = item.screenLabel {
                    Text(label)
                        .font(.caption2)
                        .lineLimit(1)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(.thinMaterial))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 150, alignment: .leading)
                        .padding(4)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isHovered ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 2)
        )
        .shadow(radius: 8, y: 3)
        .scaleEffect(isHovered ? 1.02 : 1.0)
        .animation(.easeInOut(duration: 0.12), value: isHovered)
        .onHover { hovering in isHovered = hovering }
    }

    /// Single-weight line icon, secondary until hovered — one visual family.
    private func controlButton(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.secondary)
                .frame(width: 16, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

// MARK: - Thumbnail capture

func captureWindowThumbnail(windowID: CGWindowID, targetSize: CGSize) -> NSImage? {
    guard let cgImage = CGWindowListCreateImage(
        .null,
        .optionIncludingWindow,
        windowID,
        [.boundsIgnoreFraming, .shouldBeOpaque]
    ) else { return nil }

    if cgImage.width < 4 || cgImage.height < 4 { return nil }

    let rep = NSBitmapImageRep(cgImage: cgImage)
    let result = NSImage(size: targetSize)
    result.addRepresentation(rep)
    return result
}
