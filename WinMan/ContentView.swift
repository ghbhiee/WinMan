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
            Toggle("启用 Dock 图标点击切换窗口", isOn: $isToggleEnabled)
                .onChange(of: isToggleEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "ToggleEnabled")
                    NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                }

            Divider()

            Toggle("悬停时显示多窗口预览", isOn: $isPreviewEnabled)
                .onChange(of: isPreviewEnabled) { newValue in
                    UserDefaults.standard.set(newValue, forKey: "PreviewEnabled")
                    NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                }

            if isPreviewEnabled {
                HStack {
                    Text("悬停延迟：\(hoverDelay, specifier: "%.1f") 秒")
                        .frame(width: 145, alignment: .leading)
                    Slider(value: $hoverDelay, in: 0.3...3.0, step: 0.1)
                        .onChange(of: hoverDelay) { newValue in
                            UserDefaults.standard.set(newValue, forKey: "HoverDelay")
                            NotificationCenter.default.post(name: .winManSettingsChanged, object: nil)
                        }
                }
            }

            Divider()

            Toggle("登录时自动启动 WinMan", isOn: $launchAtLogin)
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
                Text("辅助功能权限")
                Spacer()
                Text(accessibilityGranted ? "已授权" : "未授权")
                    .foregroundColor(accessibilityGranted ? .green : .red)
            }
            .font(.footnote)

            HStack {
                Text("屏幕录制权限（窗口缩略图，可选）")
                Spacer()
                if screenCaptureGranted {
                    Text("已授权").foregroundColor(.green)
                } else {
                    Button("申请") { _ = CGRequestScreenCaptureAccess() }
                }
            }
            .font(.footnote)

            Text("Dock 读取只需辅助功能权限；Automation 仅用于 Finder 窗口管理。屏幕录制仅用于窗口缩略图，授权后需重新打开 WinMan 生效。")
                .font(.footnote)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.leading)
        }
        .padding()
        .frame(width: 390, height: isPreviewEnabled ? 360 : 320)
        .onAppear {
            refreshPermissionStatus()
            let status = SMAppService.mainApp.status
            launchAtLogin = status == .enabled || status == .requiresApproval
            if status == .requiresApproval {
                loginItemMessage = "请在“系统设置 > 通用 > 登录项”中允许 WinMan。"
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
            loginItemMessage = "登录项设置失败：\(error.localizedDescription)"
        }
    }
}

extension Notification.Name {
    static let winManSettingsChanged = Notification.Name("WinManSettingsChanged")
}
