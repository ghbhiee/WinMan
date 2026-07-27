#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$project_dir/WinMan/Info.plist")"
build_dir="$(mktemp -d /tmp/winman-release.XXXXXX)"
dist_dir="$project_dir/dist"
app_name="WinMan"
app_path="$build_dir/Build/Products/Release/$app_name.app"
zip_path="$dist_dir/$app_name-$version-universal.zip"
dmg_path="$dist_dir/$app_name-$version-universal.dmg"
team_id="${WINMAN_TEAM_ID:-745N3XBC4U}"

trap 'rm -rf "$build_dir"' EXIT

build_arguments=(
  -project "$project_dir/WinMan.xcodeproj"
  -scheme WinMan
  -configuration Release
  -destination "generic/platform=macOS"
  -derivedDataPath "$build_dir"
  "ARCHS=arm64 x86_64"
  ONLY_ACTIVE_ARCH=NO
  "DEVELOPMENT_TEAM=$team_id"
)

if [[ -n "${WINMAN_SIGN_IDENTITY:-}" ]]; then
  build_arguments+=(
    CODE_SIGN_STYLE=Manual
    "CODE_SIGN_IDENTITY=$WINMAN_SIGN_IDENTITY"
  )
fi

xcodebuild "${build_arguments[@]}" build

codesign --verify --deep --strict --verbose=2 "$app_path"
file "$app_path/Contents/MacOS/WinMan"

mkdir -p "$dist_dir"
rm -rf "$dist_dir/$app_name.app"
rm -f "$zip_path" "$dmg_path" "$dist_dir/SHA256SUMS.txt"
ditto "$app_path" "$dist_dir/$app_name.app"

package_release() {
  rm -f "$zip_path" "$dmg_path"
  ditto -c -k --sequesterRsrc --keepParent "$dist_dir/$app_name.app" "$zip_path"
  hdiutil create \
    -volname "$app_name" \
    -srcfolder "$dist_dir/$app_name.app" \
    -ov \
    -format UDZO \
    "$dmg_path"
}

package_release

if [[ -n "${WINMAN_NOTARY_PROFILE:-}" ]]; then
  if ! codesign -dv --verbose=4 "$dist_dir/$app_name.app" 2>&1 | grep -q "Developer ID Application"; then
    echo "WINMAN_NOTARY_PROFILE requires a Developer ID Application signature." >&2
    exit 1
  fi

  xcrun notarytool submit "$zip_path" \
    --keychain-profile "$WINMAN_NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$dist_dir/$app_name.app"
  package_release
  xcrun notarytool submit "$dmg_path" \
    --keychain-profile "$WINMAN_NOTARY_PROFILE" \
    --wait
  xcrun stapler staple "$dmg_path"
fi

(
  cd "$dist_dir"
  shasum -a 256 \
    "$(basename "$zip_path")" \
    "$(basename "$dmg_path")" \
    > SHA256SUMS.txt
)

echo "Release artifacts:"
echo "  $zip_path"
echo "  $dmg_path"
echo "  $dist_dir/SHA256SUMS.txt"
