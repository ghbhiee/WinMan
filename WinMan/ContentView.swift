import SwiftUI
import ApplicationServices
import ServiceManagement
import CoreGraphics

struct ContentView: View {
    @State private var isToggleEnabled: Bool = {
        UserDefaults.standard.object(forKey: "ToggleEnabled") == nil ? true
            : UserDefaults.standard.bool(forKey: "ToggleEnabled")
    }()
    @State private var isPreviewEnabled: Bool = {
        UserDefaults.standard.object(forKey: "PreviewEnabled") == nil ? true
            : UserDefaults.standard.bool(forKey: "PreviewEnabled")
    }()
    @State private var hoverDelay: Double = {
        let v = UserDefaults.standard.double(forKey: "HoverDelay")
        return v == 0 ? 0.5 : v
    }()
    @State private var managedBundleIDs: [String] = ManagedApps.load()
    @State private var singleWindowPreview =
        UserDefaults.standard.bool(forKey: "PreviewSingleWindow")
    @State private var switcherEnabled: Bool = {
        UserDefaults.standard.object(forKey: "SwitcherEnabled") == nil ? true
            : UserDefaults.standard.bool(forKey: "SwitcherEnabled")
    }()
    @State private var launchAtLogin: Bool = {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }()
    @State private var loginItemMessage: String?
    @State private var accessibilityGranted = AXIsProcessTrusted()
    @State private var screenCaptureGranted = CGPreflightScreenCaptureAccess()

    private let permissionRefresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(tr("启用 Dock 图标点击切换窗口", "Toggle windows by clicking Dock icons"), isOn: $isToggleEnabled)
                .onChange(of: isToggleEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ToggleEnabled")
                    NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                }

            Divider()

            managedAppsSection

            Divider()

            Toggle(tr("悬停白名单应用图标时显示窗口预览", "Show window previews when hovering allowlisted apps"), isOn: $isPreviewEnabled)
                .onChange(of: isPreviewEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "PreviewEnabled")
                    NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                }

            if isPreviewEnabled {
                HStack {
                    Text(tr("悬停延迟：", "Hover delay: ") + String(format: "%.1f", hoverDelay) + tr(" 秒", " s"))
                        .frame(width: 145, alignment: .leading)
                    Slider(value: $hoverDelay, in: 0.2...3.0, step: 0.1)
                        .onChange(of: hoverDelay) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "HoverDelay")
                            NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                        }
                }

                Toggle(tr("只有一个窗口时也显示预览", "Preview even for a single window"), isOn: $singleWindowPreview)
                    .onChange(of: singleWindowPreview) { newValue in
                        UserDefaults.standard.set(newValue, forKey: "PreviewSingleWindow")
                        NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                    }
            }

            Divider()

            Toggle(tr("⌥Tab 全局窗口切换（含最小化窗口）", "⌥Tab window switcher (incl. minimized)"), isOn: $switcherEnabled)
                .onChange(of: switcherEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "SwitcherEnabled")
                    NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                }

            Divider()

            Toggle(tr("登录时自动启动 WinMan", "Launch WinMan at login"), isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { newValue in
                    updateLaunchAtLogin(newValue)
                }

            if let loginItemMessage {
                Text(loginItemMessage)
                    .font(.caption)
                    .foregroundColor(.orange)
            }

            Divider()

            HStack {
                Text(tr("辅助功能权限", "Accessibility permission"))
                Spacer()
                Text(accessibilityGranted ? tr("已授权", "Granted") : tr("未授权", "Not granted"))
                    .foregroundColor(accessibilityGranted ? .green : .red)
            }
            .font(.footnote)

            HStack {
                Text(tr("屏幕录制权限（窗口缩略图，可选）", "Screen Recording (thumbnails, optional)"))
                Spacer()
                if screenCaptureGranted {
                    Text(tr("已授权", "Granted")).foregroundColor(.green)
                } else {
                    Button(tr("申请", "Request")) { _ = CGRequestScreenCaptureAccess() }
                }
            }
            .font(.footnote)

            Text(tr("WinMan 只需要辅助功能权限。屏幕录制仅用于窗口缩略图，授权后需重新打开 WinMan 生效。",
                    "WinMan needs only Accessibility. Screen Recording only powers thumbnails; relaunch WinMan after granting it."))
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding()
        .frame(width: 400)
        .onAppear {
            refreshPermissionStatus()
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled || status == .requiresApproval
            if status == .requiresApproval {
                loginItemMessage = tr("请在“系统设置 > 通用 > 登录项”中允许 WinMan。",
                                      "Please allow WinMan in System Settings > General > Login Items.")
            }
        }
        .onReceive(permissionRefresh) { _ in
            refreshPermissionStatus()
        }
    }

    private func refreshPermissionStatus() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
    }

    // MARK: - Single-view allowlist

    private var managedAppsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(tr("单视图模式应用（白名单）", "Single-view mode apps (allowlist)"))
                    .font(.footnote.weight(.semibold))
                Spacer()
                Menu {
                    let candidates = ManagedApps.candidates(excluding: managedBundleIDs)
                    if candidates.isEmpty {
                        Text(tr("没有可添加的运行中应用", "No running apps to add"))
                    }
                    ForEach(candidates, id: \.bundleID) { candidate in
                        Button(candidate.name) { addManagedApp(candidate.bundleID) }
                    }
                } label: {
                    Label(tr("添加运行中的应用", "Add running app"), systemImage: "plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(tr("这些应用的窗口像 Windows 任务栏一样逐个管理：悬停预览、单窗口打开不带出其他窗口、点击始终切换最近处理的窗口。其他应用保持 macOS 原生行为。",
                    "Windows of these apps are managed one at a time like the Windows taskbar: hover previews, opening one window without dragging the others along, and clicks always toggle the window handled last. Other apps keep native macOS behavior."))
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(managedBundleIDs, id: \.self) { bundleID in
                HStack(spacing: 8) {
                    if let icon = ManagedApps.icon(for: bundleID) {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 18, height: 18)
                    }
                    Text(ManagedApps.displayName(for: bundleID))
                    Text(bundleID)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button {
                        removeManagedApp(bundleID)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.plain)
                    .foregroundColor(.secondary)
                    .help(tr("移出白名单", "Remove from allowlist"))
                }
                .font(.footnote)
            }
            if managedBundleIDs.isEmpty {
                Text(tr("白名单为空：所有应用都是原生行为。", "Allowlist is empty: every app behaves natively."))
                    .font(.caption)
                    .foregroundColor(.orange)
            }
        }
    }

    private func addManagedApp(_ bundleID: String) {
        guard !managedBundleIDs.contains(bundleID) else { return }
        managedBundleIDs.append(bundleID)
        ManagedApps.save(managedBundleIDs)
    }

    private func removeManagedApp(_ bundleID: String) {
        managedBundleIDs.removeAll { $0 == bundleID }
        ManagedApps.save(managedBundleIDs)
    }

    private func updateLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status == .notRegistered {
                    try SMAppService.mainApp.register()
                }
                loginItemMessage = SMAppService.mainApp.status == .requiresApproval
                    ? "请在“系统设置 > 通用 > 登录项”中允许 WinMan。"
                    : nil
            } else {
                if SMAppService.mainApp.status != .notRegistered {
                    try SMAppService.mainApp.unregister()
                }
                loginItemMessage = nil
            }
        } catch {
            loginItemMessage = tr("登录项设置失败：", "Failed to update login item: ") + error.localizedDescription
        }
    }
}

extension Notification.Name {
    static let winManSettingsChanged = Notification.Name("WinManSettingsChanged")
}
