import Cocoa
import Combine

struct DockItem: Equatable {
    let rect: NSRect
    let name: String

    static func == (lhs: DockItem, rhs: DockItem) -> Bool {
        return lhs.name == rhs.name && lhs.rect == rhs.rect
    }
}

class DockMonitor: ObservableObject {
    @Published private(set) var items: [DockItem] = []
    @Published private(set) var isAvailable = false
    @Published private(set) var lastError: String?

    private var isFetching = false
    private var lastRefreshStartedAt = Date.distantPast

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

    func refreshIfNeeded(maxAge: TimeInterval = 2.0) {
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
                    self.isAvailable = true
                    self.lastError = nil
                    print("[DockMonitor] Updated \(items.count) dock items")
                case .failure(let error):
                    self.isAvailable = false
                    self.lastError = error.localizedDescription
                    print("[DockMonitor] \(error.localizedDescription)")
                }
            }
        }
    }

    private func fetchDockRects(
        completion: @escaping (Result<[DockItem], Error>) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            var dockItems: [DockItem] = []

            let script = """
            tell application "System Events"
                set dockItemList to {}
                tell process "Dock"
                    set dockElements to every UI element of list 1
                    repeat with dockElement in dockElements
                        set dockPosition to position of dockElement
                        set dockSize to size of dockElement
                        set appName to name of dockElement
                        set end of dockItemList to {dockPosition, dockSize, appName}
                    end repeat
                    return dockItemList
                end tell
            end tell
            """

            guard let appleScript = NSAppleScript(source: script) else {
                completion(.failure(DockMonitorError.invalidScript))
                return
            }

            var errorInfo: NSDictionary?
            let result = appleScript.executeAndReturnError(&errorInfo)
            if let errorInfo {
                completion(.failure(DockMonitorError.appleScript(errorInfo.description)))
                return
            }

            guard result.descriptorType == typeAEList else {
                completion(.failure(DockMonitorError.invalidResult))
                return
            }

            if result.numberOfItems > 0 {
                for index in 1...result.numberOfItems {
                    guard let item = result.atIndex(index),
                          let posDesc = item.atIndex(1),
                          let sizeDesc = item.atIndex(2),
                          let nameDesc = item.atIndex(3) else { continue }

                    let x = posDesc.atIndex(1)?.doubleValue ?? 0
                    let y = posDesc.atIndex(2)?.doubleValue ?? 0
                    let width = sizeDesc.atIndex(1)?.doubleValue ?? 0
                    let height = sizeDesc.atIndex(2)?.doubleValue ?? 0
                    let name = nameDesc.stringValue ?? "Unknown"

                    guard width > 0, height > 0 else { continue }
                    dockItems.append(DockItem(
                        rect: NSRect(x: x, y: y, width: width, height: height),
                        name: name
                    ))
                }
            }

            completion(.success(dockItems))
        }
    }
}

private enum DockMonitorError: LocalizedError {
    case invalidScript
    case invalidResult
    case appleScript(String)

    var errorDescription: String? {
        switch self {
        case .invalidScript:
            return "Unable to create the Dock automation script."
        case .invalidResult:
            return "System Events returned an invalid Dock item list."
        case .appleScript(let message):
            return "Dock automation failed: \(message)"
        }
    }
}
