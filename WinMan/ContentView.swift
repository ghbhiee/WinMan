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
        return v == 0 ? 1.0 : v
    }()
    @State private var singleWindowPreview =
        UserDefaults.standard.bool(forKey: "PreviewSingleWindow")
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

            Toggle(tr("悬停时显示多窗口预览", "Show window previews on hover"), isOn: $isPreviewEnabled)
                .onChange(of: isPreviewEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "PreviewEnabled")
                    NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                }

            if isPreviewEnabled {
                HStack {
                    Text(tr("悬停延迟：", "Hover delay: ") + String(format: "%.1f", hoverDelay) + tr(" 秒", " s"))
                        .frame(width: 145, alignment: .leading)
                    Slider(value: $hoverDelay, in: 0.3...3.0, step: 0.1)
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

            Text(tr("Dock 读取只需辅助功能权限；Automation 仅用于 Finder 窗口管理。屏幕录制仅用于窗口缩略图，授权后需重新打开 WinMan 生效。",
                    "Reading the Dock needs only Accessibility; Automation is used solely for Finder window management. Screen Recording only powers thumbnails; relaunch WinMan after granting it."))
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .frame(width: 390, height: isPreviewEnabled ? 390 : 320)
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
