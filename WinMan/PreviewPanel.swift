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
    }

    func show(
        for app: NSRunningApplication,
        windows: [WindowPreviewItem],
        nearDockRect dockRect: NSRect,
        onSelect: @escaping (AXUIElement, NSRunningApplication) -> Void,
        onCloseWindow: @escaping (WindowPreviewItem) -> Void
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
        let panelSize = CGSize(width: panelWidth, height: 200)
        let frame = ScreenGeometry.previewFrame(
            panelSize: panelSize,
            dockRect: appKitDockRect,
            screenFrame: screenFrame
        )
        self.setFrame(frame, display: false)

        let view = PreviewPanelView(
            windows: windows,
            appIcon: app.icon,
            onSelect: { element in onSelect(element, app) },
            onClose: { [weak self] in self?.dismiss() },
            onCloseWindow: onCloseWindow
        )

        if let hv = hostingView {
            hv.rootView = view
            hv.frame = NSRect(origin: .zero, size: frame.size)
        } else {
            let hv = NSHostingView(rootView: view)
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

struct PreviewPanelView: View {
    let windows: [WindowPreviewItem]
    let appIcon: NSImage?
    let onSelect: (AXUIElement) -> Void
    let onClose: () -> Void
    let onCloseWindow: (WindowPreviewItem) -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(windows) { item in
                        WindowThumbnailView(
                            item: item,
                            appIcon: appIcon,
                            onCloseWindow: { onCloseWindow(item) }
                        )
                        .onTapGesture { onSelect(item.element) }
                    }
                }
                .padding(.horizontal, 10)
                .padding(.top, 28)   // leave room for close button
                .padding(.bottom, 10)
            }

            // X close button
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 16))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .padding(6)
            .contentShape(Rectangle())
        }
        .frame(height: 200)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(radius: 10, y: 4)
    }
}

struct WindowThumbnailView: View {
    let item: WindowPreviewItem
    let appIcon: NSImage?
    let onCloseWindow: () -> Void
    @State private var isHovered = false

    var body: some View {
        VStack(spacing: 4) {
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered
                          ? Color.accentColor.opacity(0.25)
                          : Color(nsColor: .windowBackgroundColor).opacity(0.5))
                    .frame(width: 160, height: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(isHovered ? Color.accentColor.opacity(0.6) : Color.clear, lineWidth: 2)
                    )

                if let thumb = item.thumbnail {
                    Image(nsImage: thumb)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 156, height: 116)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                } else if let icon = appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 56, height: 56)
                        .opacity(0.45)
                        .frame(width: 160, height: 120)
                }

                // Windows-taskbar-style per-window close button, hover-revealed
                if isHovered {
                    Button(action: onCloseWindow) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 15))
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, .red.opacity(0.85))
                            .shadow(radius: 1)
                    }
                    .buttonStyle(.plain)
                    .padding(4)
                    .help(tr("关闭窗口", "Close window"))
                }
            }
            .scaleEffect(isHovered ? 1.03 : 1.0)
            .animation(.easeInOut(duration: 0.12), value: isHovered)

            Text(item.title.isEmpty ? "Window" : item.title)
                .font(.caption)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 160)
                .foregroundStyle(isHovered ? .primary : .secondary)
        }
        .onHover { hovering in isHovered = hovering }
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
