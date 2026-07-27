# WinMan

[中文](README.md) | [English](README_EN.md)

WinMan is a lightweight macOS menu bar utility that makes Dock icons behave
more like buttons on the Windows taskbar.

## Why WinMan Exists

macOS has always approached window management very differently from Windows.
It is difficult to claim that either model is inherently more reasonable:
macOS emphasizes applications and multi-document workflows, while Windows tends
to make individual windows the objects users interact with directly.

I used Windows for many years, and I still use Windows and macOS side by side
every day. Even though I understand the reasoning behind the macOS model, I
often find its window interactions difficult to tolerate in practice.

`Cmd-M` minimizes one window, while `Cmd-H` hides the entire application. The
Dock usually provides one icon for an application instead of a direct entry for
each window. Understanding the multi-document model does not make these actions
fit what I need from window management.

I prefer a more direct, what-you-see-is-what-you-get interaction:

- Click a Dock icon to show a window.
- Click the same icon again to put the window away.
- Repeated clicks on one button toggle between visible and minimized states.

This is not only a Windows convention. Toggle-style interactions are common in
many software products. They let users inspect, dismiss, and restore something
without moving the pointer to another control or opening a context menu. WinMan
exists to solve this small interaction problem that otherwise repeats many
times every day.

Multi-document applications make the problem more complicated. WinMan currently
shows window previews when the pointer hovers over an application icon. This is
a compromise that works with the macOS application model, but it is not perfect.
When windows are created or closed quickly, Accessibility state can lag briefly,
so the last-active-window choice or preview order may occasionally be less than
ideal.

An early version of the project also experimented with representing each
document from the same application as a separate Dock icon. That seemed closer
to the Windows taskbar, where every window can be clicked directly. In practice,
it conflicted with the macOS application lifecycle, focus handling, and Dock
model, creating more problems than it solved, so the approach was removed.

WinMan is not an argument that Windows is more correct than macOS, nor is it an
attempt to turn macOS into Windows. It simply adds an optional and consistent
interaction for people who use both platforms and prefer direct window toggling.

## Features

- Click the frontmost application's Dock icon to minimize its most recently
  active window.
- Click the same icon again to restore the last active or minimized window.
- Hover over an application with multiple windows to see clickable previews.
- Restore Finder windows minimized through `Cmd-M`, the yellow minimize button,
  or a WinMan Dock click.
- Remember the most recently used window in multi-window applications.
- Support bottom, top, left, and right Dock positions across multiple displays.
- Configure hover delay, disable previews, and choose whether WinMan starts at
  login.

## Requirements

- macOS 13 Ventura or later.
- Apple Silicon or Intel Mac.

## Installation

Download the latest build from
[GitHub Releases](https://github.com/ghbhiee/WinMan/releases), move
`WinMan.app` to `/Applications`, and open it.

The current public build is signed with an Apple Development certificate but is
not yet notarized with Developer ID. If macOS blocks the first launch, right-click
`WinMan.app` in Finder and choose **Open**. The release script already supports
notarization and stapling for a future Developer ID build.

## Permissions

WinMan uses the following macOS permissions:

- Accessibility: required to inspect, minimize, and restore windows.
- Automation: required to read Dock icon positions through System Events and to
  manage Finder windows.
- Screen Recording: optional and used only for live window preview thumbnails.

The Bundle ID is fixed at `com.winman.app`. Builds signed with the same Apple
certificate keep a stable permission identity instead of receiving a new
CDHash-only identity after every ad-hoc build. Switching from an older ad-hoc
build to a stable signed build may require one final authorization.

## Building

```bash
git clone https://github.com/ghbhiee/WinMan.git
cd WinMan
./scripts/test.sh
xcodebuild -project WinMan.xcodeproj -scheme WinMan -configuration Debug build
```

The project defaults to the author's Apple Development Team. Other developers
can select their own team in Xcode Signing settings or override
`DEVELOPMENT_TEAM` on the command line.

Build a Universal Release:

```bash
./scripts/build-release.sh
```

Build with Developer ID and notarization:

```bash
WINMAN_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
WINMAN_TEAM_ID="TEAMID" \
WINMAN_NOTARY_PROFILE="notary-profile" \
./scripts/build-release.sh
```

## Privacy

WinMan does not upload window titles, screenshots, or usage data, and it contains
no analytics services. Window thumbnails are generated only in local memory.
The only network link in the application opens the GitHub project page.

## Known Limitations

- Window-to-thumbnail association uses the private Accessibility symbol
  `_AXUIElementGetWindow`, so the Mac App Store is not currently a target.
- Some applications do not expose standard Accessibility window attributes.
  When an operation fails, WinMan passes the original Dock click back to macOS.
- The first launch of a non-notarized build is still subject to Gatekeeper.

## Author

Author: Guohongbo

Contact: ghbhiee@gmail.com

GitHub: [ghbhiee/WinMan](https://github.com/ghbhiee/WinMan)

## License

Copyright (c) 2026 Guohongbo. All rights reserved. See [LICENSE](LICENSE).
