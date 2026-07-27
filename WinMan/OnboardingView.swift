import SwiftUI
import Cocoa
import ApplicationServices

// MARK: - Permission probes

enum AutomationStatus {
    case granted
    case denied
    case notDetermined
}

enum PermissionProbe {
    /// Passive Automation (Apple Events → System Events) check; never prompts.
    static func automationStatus() -> AutomationStatus {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.systemevents")
        guard let sourceDesc = target.aeDesc else { return .notDetermined }
        var address = AEAddressDesc()
        guard AEDuplicateDesc(sourceDesc, &address) == noErr else { return .notDetermined }
        defer { AEDisposeDesc(&address) }

        let status = AEDeterminePermissionToAutomateTarget(
            &address,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )
        switch Int(status) {
        case 0:
            return .granted
        case -1743:  // errAEEventNotPermitted
            return .denied
        default:  // -1744 not yet asked, -600 System Events not running, …
            return .notDetermined
        }
    }

    /// Sends one harmless Apple Event to System Events, which launches it if
    /// needed and triggers the system consent dialog on first use.
    static func requestAutomation(completion: @escaping (Bool) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            var error: NSDictionary?
            let script = NSAppleScript(source: "tell application \"System Events\" to count processes")
            let result = script?.executeAndReturnError(&error)
            DispatchQueue.main.async { completion(result != nil) }
        }
    }

    /// Shows the system Accessibility consent dialog (no-op if already granted).
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - Onboarding wizard

struct OnboardingView: View {
    @State private var axGranted = AXIsProcessTrusted()
    @State private var automationStatus = PermissionProbe.automationStatus()
    @State private var screenGranted = CGPreflightScreenCaptureAccess()
    @State private var checkingAutomation = false

    let openSecurityPane: (String) -> Void
    let onDone: () -> Void

    private let refresh = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text(tr("欢迎使用 WinMan", "Welcome to WinMan"))
                    .font(.title2.bold())
                Text(tr("让 Dock 图标像 Windows 任务栏一样：点击切换窗口，悬停预览多窗口。开始前需要完成以下授权。",
                        "Make Dock icons behave like the Windows taskbar: click to toggle windows, hover to preview. A few permissions are needed first."))
                    .font(.callout)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            permissionRow(
                granted: axGranted,
                required: true,
                title: tr("辅助功能", "Accessibility"),
                detail: tr("读取 Dock 图标位置、读取和改变窗口状态。",
                           "Reads Dock icon positions and manages window state.")
            ) {
                Button(tr("授权", "Grant")) {
                    PermissionProbe.requestAccessibility()
                    openSecurityPane("Privacy_Accessibility")
                }
            }

            permissionRow(
                granted: automationStatus == .granted,
                required: true,
                title: tr("自动化（System Events）", "Automation (System Events)"),
                detail: tr("仅用于 Finder 窗口的最小化与恢复。",
                           "Used only to minimize and restore Finder windows.")
            ) {
                if checkingAutomation {
                    ProgressView().controlSize(.small)
                } else {
                    Button(tr("授权", "Grant")) {
                        if automationStatus == .denied {
                            openSecurityPane("Privacy_Automation")
                        } else {
                            checkingAutomation = true
                            PermissionProbe.requestAutomation { _ in
                                checkingAutomation = false
                                automationStatus = PermissionProbe.automationStatus()
                            }
                        }
                    }
                }
            }

            permissionRow(
                granted: screenGranted,
                required: false,
                title: tr("屏幕录制", "Screen Recording"),
                detail: tr("可选，仅用于悬停预览中的实时窗口缩略图；授权后需重新打开 WinMan。",
                           "Optional; only for live window thumbnails in hover previews. Relaunch WinMan after granting.")
            ) {
                Button(tr("申请", "Request")) {
                    if !CGRequestScreenCaptureAccess() {
                        openSecurityPane("Privacy_ScreenCapture")
                    }
                }
            }

            Divider()

            HStack {
                Text(tr("之后可随时从菜单栏打开「设置向导」。",
                        "You can reopen this guide from the menu bar at any time."))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: onDone) {
                    Text(tr("开始使用", "Get Started"))
                }
                .keyboardShortcut(.defaultAction)
                .disabled(!axGranted)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onReceive(refresh) { _ in
            axGranted = AXIsProcessTrusted()
            screenGranted = CGPreflightScreenCaptureAccess()
            if !checkingAutomation {
                automationStatus = PermissionProbe.automationStatus()
            }
        }
    }

    @ViewBuilder
    private func permissionRow<Action: View>(
        granted: Bool,
        required: Bool,
        title: String,
        detail: String,
        @ViewBuilder action: () -> Action
    ) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundColor(granted ? .green : (required ? .orange : .secondary))
                .frame(width: 24)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(title).font(.body.weight(.medium))
                    if !required {
                        Text(tr("可选", "Optional"))
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.15)))
                            .foregroundColor(.secondary)
                    }
                }
                Text(detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if !granted {
                action()
            }
        }
    }
}
