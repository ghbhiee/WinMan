import Cocoa
import Combine
import ApplicationServices
import os

struct DockItem: Equatable {
    let rect: NSRect
    let name: String
    /// File URL of the app the dock item represents (AXURL); nil for folders,
    /// the Trash, separators, and items whose URL the Dock does not expose.
    let bundleURL: URL?
    /// Resolved from bundleURL — lets clicks match running apps exactly instead
    /// of guessing from localized display names.
    let bundleID: String?
    let subrole: String?

    /// Only application items are click-toggle candidates; folders, the Trash,
    /// and separators keep native behavior. A missing subrole is treated as an
    /// application so behavior degrades to the pre-AX matching path.
    var isApplication: Bool {
        subrole == nil || subrole == "AXApplicationDockItem"
    }

    /// Stable identity across refreshes, independent of display language.
    var identity: String { bundleURL?.absoluteString ?? name }
}

class DockMonitor: ObservableObject {
    @Published private(set) var items: [DockItem] = []
    @Published private(set) var isAvailable = false
    @Published private(set) var lastError: String?

    private var isFetching = false
    private var lastRefreshStartedAt = Date.distantPast

    // Union of all dock item rects, generously expanded — cheap "is the pointer
    // anywhere near the Dock" test recomputed whenever items change.
    private var expandedDockBounds = CGRect.null

    private let fetchQueue = DispatchQueue(label: "com.winman.dock-fetch", qos: .userInitiated)
    // URL → bundle identifier; reading Info.plist once per app is enough.
    // Only touched on fetchQueue.
    private var bundleIDCache: [URL: String] = [:]

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
    }

    func startObserving() {
        let center = NSWorkspace.shared.notificationCenter
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didActivateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        center.addObserver(self, selector: #selector(dockChanged), name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        sync(force: true)
    }

    @objc func dockChanged() {
        sync(force: true)
    }

    /// Called on every pointer move. Reads the Dock frequently only while the
    /// pointer is near it; elsewhere a slow fallback keeps stale coordinates
    /// from surviving a Dock move indefinitely.
    func refreshIfNeeded(near location: CGPoint) {
        let nearDock = items.isEmpty || expandedDockBounds.contains(location)
        let maxAge: TimeInterval = nearDock ? 2.0 : 20.0
        sync(force: Date().timeIntervalSince(lastRefreshStartedAt) >= maxAge)
    }

    func sync(force: Bool = false) {
        if !Thread.isMainThread {
            DispatchQueue.main.async { [weak self] in self?.sync(force: force) }
            return
        }

        guard !isFetching else { return }
        guard force || Date().timeIntervalSince(lastRefreshStartedAt) >= 0.5 else { return }

        isFetching = true
        lastRefreshStartedAt = Date()
        fetchDockRects { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isFetching = false

                switch result {
                case .success(let items):
                    self.items = items
                    self.expandedDockBounds = items
                        .reduce(CGRect.null) { $0.union($1.rect) }
                        .insetBy(dx: -200, dy: -200)
                    self.isAvailable = true
                    self.lastError = nil
                    WinManLog.dock.debug("Updated \(items.count) dock items")
                case .failure(let error):
                    self.isAvailable = false
                    self.lastError = error.localizedDescription
                    WinManLog.dock.error("\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    /// Reads dock items straight from the Dock process's accessibility tree —
    /// the same data System Events proxies, but without Apple Events, without
    /// the Automation permission, and with the AXURL attribute that identifies
    /// each app independent of the display language. Positions are Quartz
    /// global coordinates, identical to what the AppleScript returned.
    private func fetchDockRects(
        completion: @escaping (Result<[DockItem], Error>) -> Void
    ) {
        fetchQueue.async { [weak self] in
            guard let self else { return }

            guard AXIsProcessTrusted() else {
                completion(.failure(DockMonitorError.accessibilityDenied))
                return
            }
            guard let dockApp = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.apple.dock").first else {
                completion(.failure(DockMonitorError.dockNotRunning))
                return
            }

            let dockElement = AXUIElementCreateApplication(dockApp.processIdentifier)
            guard let children = Self.attribute(dockElement, kAXChildrenAttribute) as? [AXUIElement],
                  let list = children.first(where: {
                      Self.stringAttribute($0, kAXRoleAttribute) == kAXListRole
                  }),
                  let itemElements = Self.attribute(list, kAXChildrenAttribute) as? [AXUIElement] else {
                completion(.failure(DockMonitorError.dockUnreadable))
                return
            }

            var dockItems: [DockItem] = []
            for element in itemElements {
                guard let position = Self.pointAttribute(element, kAXPositionAttribute),
                      let size = Self.sizeAttribute(element, kAXSizeAttribute),
                      size.width > 0, size.height > 0 else { continue }

                let name = Self.stringAttribute(element, kAXTitleAttribute) ?? "Unknown"
                let subrole = Self.stringAttribute(element, kAXSubroleAttribute)
                let url = Self.attribute(element, kAXURLAttribute) as? URL

                var bundleID: String?
                if subrole == "AXApplicationDockItem", let url {
                    if let cached = self.bundleIDCache[url] {
                        bundleID = cached
                    } else if let resolved = Bundle(url: url)?.bundleIdentifier {
                        bundleID = resolved
                        self.bundleIDCache[url] = resolved
                    }
                }

                dockItems.append(DockItem(
                    rect: NSRect(origin: position, size: size),
                    name: name,
                    bundleURL: url,
                    bundleID: bundleID,
                    subrole: subrole
                ))
            }

            completion(.success(dockItems))
        }
    }

    // MARK: - AX attribute helpers

    private static func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else {
            return nil
        }
        return value
    }

    private static func stringAttribute(_ element: AXUIElement, _ name: String) -> String? {
        attribute(element, name) as? String
    }

    private static func pointAttribute(_ element: AXUIElement, _ name: String) -> CGPoint? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(value as! AXValue, .cgPoint, &point) else { return nil }
        return point
    }

    private static func sizeAttribute(_ element: AXUIElement, _ name: String) -> CGSize? {
        guard let value = attribute(element, name),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(value as! AXValue, .cgSize, &size) else { return nil }
        return size
    }
}

private enum DockMonitorError: LocalizedError {
    case accessibilityDenied
    case dockNotRunning
    case dockUnreadable

    var errorDescription: String? {
        switch self {
        case .accessibilityDenied:
            return "Accessibility permission is required to read the Dock."
        case .dockNotRunning:
            return "The Dock process is not running."
        case .dockUnreadable:
            return "The Dock's accessibility tree could not be read."
        }
    }
}
