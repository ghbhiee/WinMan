#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
test_dir="$(mktemp -d /tmp/winman-tests.XXXXXX)"
trap 'rm -rf "$test_dir"' EXIT

xcrun swiftc \
  "$project_dir/WinMan/ScreenGeometry.swift" \
  "$project_dir/WinMan/InteractionPolicy.swift" \
  "$project_dir/Tests/ScreenGeometryTests.swift" \
  "$project_dir/Tests/InteractionPolicyTests.swift" \
  -framework Cocoa \
  -o "$test_dir/ScreenGeometryTests"

"$test_dir/ScreenGeometryTests"

xcrun swiftc \
  -typecheck \
  -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
  -target arm64-apple-macos13.0 \
  -module-name WinMan \
  "$project_dir/WinMan/AppDelegate.swift" \
  "$project_dir/WinMan/ContentView.swift" \
  "$project_dir/WinMan/DockMonitor.swift" \
  "$project_dir/WinMan/PreviewPanel.swift" \
  "$project_dir/WinMan/WindowTracker.swift" \
  "$project_dir/WinMan/ScreenGeometry.swift" \
  "$project_dir/WinMan/Localization.swift" \
  "$project_dir/WinMan/OnboardingView.swift" \
  "$project_dir/WinMan/InteractionPolicy.swift" \
  "$project_dir/WinMan/AppDelegate+EventTap.swift" \
  "$project_dir/WinMan/AppDelegate+HoverPreview.swift" \
  "$project_dir/WinMan/AppDelegate+Help.swift" \
  "$project_dir/WinMan/WindowSwitcher.swift" \
  -framework Cocoa \
  -framework SwiftUI \
  -framework CoreGraphics \
  -framework ApplicationServices \
  -framework Combine \
  -framework ServiceManagement

echo "Swift type check passed"
