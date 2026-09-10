import Cocoa

/// Manual "check for updates" against the GitHub Releases feed. Downloads the
/// universal ZIP of a newer release, verifies its signature, swaps the bundle
/// in place after the app quits, and relaunches it.
final class Updater {
    static let latestReleaseAPI = URL(string: "https://api.github.com/repos/ghbhiee/WinMan/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/ghbhiee/WinMan/releases/latest")!

    struct Release {
        let version: String
        let notes: String
        let pageURL: URL
        let zipURL: URL?
    }

    /// Called when a verified update is staged; the host must quit so the
    /// bundle can be replaced.
    var quitForInstall: (() -> Void)?

    private var isBusy = false

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Check

    func checkForUpdates() {
        guard !isBusy else { return }
        isBusy = true

        var request = URLRequest(url: Self.latestReleaseAPI, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                guard error == nil, let data, let release = Self.parseRelease(data) else {
                    self.showError(tr("无法获取更新信息。", "Could not fetch release information."),
                                   detail: error?.localizedDescription)
                    return
                }
                if SemanticVersion.compare(release.version, self.currentVersion) > 0 {
                    self.offer(release)
                } else {
                    let alert = NSAlert()
                    alert.messageText = tr("已是最新版本", "You're up to date")
                    alert.informativeText = tr("当前版本 \(self.currentVersion) 就是最新发布的版本。",
                                               "Version \(self.currentVersion) is the latest release.")
                    alert.addButton(withTitle: tr("好", "OK"))
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            }
        }.resume()
    }

    static func parseRelease(_ data: Data) -> Release? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              let page = (json["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        let zip = assets.first { ($0["name"] as? String)?.hasSuffix("-universal.zip") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        return Release(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            notes: json["body"] as? String ?? "",
            pageURL: page,
            zipURL: zip
        )
    }

    // MARK: - Offer / install

    private func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = tr("发现新版本 \(release.version)", "Version \(release.version) is available")
        var notes = release.notes.trimmingCharacters(in: .whitespacesAndNewlines)
        if notes.count > 700 { notes = String(notes.prefix(700)) + "…" }
        alert.informativeText = tr("当前版本 \(currentVersion)。\n\n", "You have \(currentVersion).\n\n") + notes
        if release.zipURL != nil {
            alert.addButton(withTitle: tr("下载并安装", "Download & Install"))
        }
        alert.addButton(withTitle: tr("查看发布页", "View Release Page"))
        alert.addButton(withTitle: tr("稍后", "Later"))
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()

        switch (response, release.zipURL) {
        case (.alertFirstButtonReturn, .some(let zip)):
            install(from: zip, version: release.version)
        case (.alertFirstButtonReturn, .none), (.alertSecondButtonReturn, .some):
            NSWorkspace.shared.open(release.pageURL)
        default:
            break
        }
    }

    private func install(from zipURL: URL, version: String) {
        isBusy = true
        let notice = NSAlert()
        notice.messageText = tr("正在下载 \(version)…", "Downloading \(version)…")
        notice.informativeText = tr("下载完成并校验签名后，WinMan 会自动退出、替换并重新启动。",
                                    "After the download is verified, WinMan will quit, replace itself, and relaunch.")
        notice.addButton(withTitle: tr("好", "OK"))
        notice.runModal()

        URLSession.shared.downloadTask(with: zipURL) { [weak self] tempURL, _, error in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isBusy = false
                guard error == nil, let tempURL else {
                    self.showError(tr("下载失败。", "Download failed."), detail: error?.localizedDescription)
                    return
                }
                do {
                    let staged = try self.stage(zipAt: tempURL)
                    self.replaceAndRelaunch(with: staged)
                } catch {
                    self.showError(tr("更新包校验失败，已放弃安装。", "The update failed verification and was not installed."),
                                   detail: error.localizedDescription)
                }
            }
        }.resume()
    }

    /// Unpack the ZIP into a private temp dir and verify the bundle before
    /// anything touches the installed copy.
    private func stage(zipAt zipURL: URL) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("winman-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zipCopy = dir.appendingPathComponent("update.zip")
        try FileManager.default.moveItem(at: zipURL, to: zipCopy)

        try run("/usr/bin/ditto", ["-x", "-k", zipCopy.path, dir.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" }) else {
            throw UpdateError.noBundle
        }
        try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        let newBundleID = Bundle(url: app)?.bundleIdentifier
        guard newBundleID == Bundle.main.bundleIdentifier else { throw UpdateError.bundleMismatch }
        return app
    }

    /// Hand the swap to a detached shell that waits for this process to exit,
    /// replaces the bundle at its current location, and relaunches it.
    private func replaceAndRelaunch(with staged: URL) {
        let dest = Bundle.main.bundleURL.path
        let script = """
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$3" && /usr/bin/ditto "$2" "$3" && /usr/bin/open "$3"
        rm -rf "$(dirname "$2")"
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "sh", String(ProcessInfo.processInfo.processIdentifier), staged.path, dest]
        do {
            try process.run()
        } catch {
            showError(tr("无法启动安装脚本。", "Could not start the installer."), detail: error.localizedDescription)
            return
        }
        quitForInstall?()
    }

    // MARK: - Helpers

    private enum UpdateError: LocalizedError {
        case noBundle, bundleMismatch, toolFailed(String, Int32)
        var errorDescription: String? {
            switch self {
            case .noBundle: return "No .app bundle found in the archive."
            case .bundleMismatch: return "The archive contains a different app."
            case .toolFailed(let tool, let code): return "\(tool) exited with status \(code)."
            }
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw UpdateError.toolFailed((tool as NSString).lastPathComponent, process.terminationStatus)
        }
    }

    private func showError(_ message: String, detail: String?) {
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail ?? ""
        alert.alertStyle = .warning
        alert.addButton(withTitle: tr("好", "OK"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
