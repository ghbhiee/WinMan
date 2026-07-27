import Cocoa
import SwiftUI
import ApplicationServices

// Option-Tab window switcher: a global, Windows-Alt-Tab-style list of windows
// across all apps in Z-order (most recent first), with minimized windows
// appended. Driven entirely from the event tap; the panel never takes focus.

struct SwitcherEntry: Identifiable {
    let id: String
    let app: NSRunningApplication
    let window: AXUIElement
    let title: String
    let isMinimized: Bool
}

final class WindowSwitcher {
    private let windowTracker: WindowTracker
    private var panel: NSPanel?
    private var hostingView: NSHostingView<SwitcherView>?

    private(set) var isActive = false
    private var entries: [SwitcherEntry] = []
    private var selectedIndex = 0

    init(windowTracker: WindowTracker) {
        self.windowTracker = windowTracker
    }

    func begin(reversed: Bool) {
        guard AXIsProcessTrusted() else { return }
        entries = collectEntries()
        guard !entries.isEmpty else { return }
        selectedIndex = SwitcherPolicy.initialIndex(count: entries.count, reversed: reversed)
        isActive = true
        showPanel()
    }

    func cycle(reversed: Bool) {
        guard isActive, !entries.isEmpty else { return }
        selectedIndex = SwitcherPolicy.nextIndex(from: selectedIndex, count: entries.count, reversed: reversed)
        updatePanel()
    }

    func commit() {
        guard isActive, entries.indices.contains(selectedIndex) else {
            hide()
            return
        }
        let entry = entries[selectedIndex]
        hide()
        windowTracker.setLastActiveWindow(entry.window, for: entry.app)
        if !windowTracker.restoreAndRaise(entry.window, app: entry.app) {
            NSSound.beep()
        }
    }

    func cancel() {
        hide()
    }

    private func hide() {
        isActive = false
        entries = []
        panel?.orderOut(nil)
    }

    // MARK: - Window enumeration

    /// Global Z-ordered on-screen windows from CGWindowList, matched to their
    /// AX elements per app; minimized windows (absent from CGWindowList) are
    /// appended afterwards, still grouped by app recency.
    private func collectEntries() -> [SwitcherEntry] {
        let myPID = pid_t(ProcessInfo.processInfo.processIdentifier)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let cgList = (CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]) ?? []

        var orderedWindows: [(pid: pid_t, wid: CGWindowID)] = []
        var orderedPIDs: [pid_t] = []
        for info in cgList {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let wid = info[kCGWindowNumber as String] as? CGWindowID else { continue }
            orderedWindows.append((pid, wid))
            if !orderedPIDs.contains(pid) { orderedPIDs.append(pid) }
        }

        // Apps that only have minimized windows never appear in CGWindowList;
        // scan the remaining regular apps so their windows are listed too.
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && app.processIdentifier != myPID
            && !orderedPIDs.contains(app.processIdentifier) {
            orderedPIDs.append(app.processIdentifier)
        }

        var appsByPID: [pid_t: NSRunningApplication] = [:]
        var axByPID: [pid_t: [(element: AXUIElement, wid: CGWindowID?, minimized: Bool)]] = [:]
        for pid in orderedPIDs {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            appsByPID[pid] = app
            axByPID[pid] = windowTracker.allWindows(for: app).map {
                ($0, windowTracker.windowID($0), windowTracker.isMinimized($0))
            }
        }

        var result: [SwitcherEntry] = []
        var usedWIDs = Set<CGWindowID>()

        for (pid, wid) in orderedWindows {
            guard let app = appsByPID[pid],
                  let axList = axByPID[pid],
                  let match = axList.first(where: { $0.wid == wid }),
                  usedWIDs.insert(wid).inserted else { continue }
            result.append(makeEntry(app: app, window: match.element, wid: wid, minimized: match.minimized))
        }

        for pid in orderedPIDs {
            guard let app = appsByPID[pid], let axList = axByPID[pid] else { continue }
            for ax in axList where ax.minimized {
                if let wid = ax.wid {
                    guard usedWIDs.insert(wid).inserted else { continue }
                }
                result.append(makeEntry(app: app, window: ax.element, wid: ax.wid, minimized: true))
            }
        }
        return result
    }

    private func makeEntry(app: NSRunningApplication, window: AXUIElement, wid: CGWindowID?, minimized: Bool) -> SwitcherEntry {
        let id: String
        if let wid {
            id = "sw:\(wid)"
        } else {
            id = "swax:\(UInt(bitPattern: Unmanaged.passUnretained(window).toOpaque()))"
        }
        let title = windowTracker.windowTitle(window) ?? ""
        return SwitcherEntry(
            id: id,
            app: app,
            window: window,
            title: title.isEmpty ? (app.localizedName ?? "Window") : title,
            isMinimized: minimized
        )
    }

    // MARK: - Panel

    private func showPanel() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 150),
                styleMask: [.nonactivatingPanel, .borderless, .hudWindow],
                backing: .buffered,
                defer: false
            )
            p.level = .popUpMenu
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            panel = p
        }
        guard let panel else { return }

        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { $0.frame.contains(mouseLocation) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screenFrame = screen?.frame else { return }

        let cellWidth: CGFloat = 128
        let width = min(CGFloat(entries.count) * cellWidth + 24, screenFrame.width - 80)
        let height: CGFloat = 150
        let frame = NSRect(
            x: screenFrame.midX - width / 2,
            y: screenFrame.midY - height / 2,
            width: width,
            height: height
        )
        panel.setFrame(frame, display: false)

        let view = SwitcherView(entries: entries, selectedIndex: selectedIndex)
        if let hv = hostingView {
            hv.rootView = view
            hv.frame = NSRect(origin: .zero, size: frame.size)
        } else {
            let hv = NSHostingView(rootView: view)
            hv.frame = NSRect(origin: .zero, size: frame.size)
            panel.contentView = hv
            hostingView = hv
        }
        panel.orderFrontRegardless()
    }

    private func updatePanel() {
        hostingView?.rootView = SwitcherView(entries: entries, selectedIndex: selectedIndex)
    }
}

// MARK: - SwiftUI

struct SwitcherView: View {
    let entries: [SwitcherEntry]
    let selectedIndex: Int

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        SwitcherCell(entry: entry, isSelected: index == selectedIndex)
                            .id(entry.id)
                    }
                }
                .padding(12)
            }
            .onAppear {
                if entries.indices.contains(selectedIndex) {
                    proxy.scrollTo(entries[selectedIndex].id, anchor: .center)
                }
            }
            .onChange(of: selectedIndex) { newIndex in
                if entries.indices.contains(newIndex) {
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(entries[newIndex].id, anchor: .center)
                    }
                }
            }
        }
        .frame(height: 150)
        .background(
            RoundedRectangle(cornerRadius: 14)
                .fill(.regularMaterial)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 14, y: 5)
    }
}

private struct SwitcherCell: View {
    let entry: SwitcherEntry
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 6) {
            ZStack(alignment: .bottomTrailing) {
                if let icon = entry.app.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 60, height: 60)
                } else {
                    Image(systemName: "macwindow")
                        .font(.system(size: 44))
                        .frame(width: 60, height: 60)
                }
                if entry.isMinimized {
                    Image(systemName: "arrow.down.right.square.fill")
                        .font(.system(size: 15))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .orange)
                }
            }
            Text(entry.title)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
                .frame(width: 108, height: 30, alignment: .top)
                .foregroundStyle(isSelected ? .primary : .secondary)
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 6)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(isSelected ? Color.accentColor.opacity(0.28) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(isSelected ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 2)
        )
    }
}
