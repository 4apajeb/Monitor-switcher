#!/bin/bash
# Builds "Monitor Switcher.app", MonitorSwitcher.exe and the release zip into ./build.
#   scripts/build.sh            build only
#   scripts/build.sh --install  build, copy to /Applications and (re)launch
#
# VERSION (env) sets the version of both apps; it defaults to the VERSION file + ".0".
set -euo pipefail
cd "$(dirname "$0")/.."

APP_NAME="Monitor Switcher"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION).0}"
echo "Building Monitor Switcher $VERSION"

swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

mkdir -p "$BUILD_DIR"
if [[ ! -f "$BUILD_DIR/AppIcon.icns" || ! -f "$BUILD_DIR/AppIcon.ico" || scripts/make-icon.swift -nt "$BUILD_DIR/AppIcon.icns" ]]; then
    swift scripts/make-icon.swift "$BUILD_DIR"
fi
cp "$BUILD_DIR/AppIcon.ico" windows/MonitorSwitcher.Win/app.ico

# Windows companion app (.NET Framework 4.8 — runs on any Windows 10/11 without installs).
WIN_EXE=""
if command -v dotnet >/dev/null 2>&1; then
    DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 \
        dotnet build windows/MonitorSwitcher.Win -c Release -v quiet -nologo -p:Version="$VERSION"
    WIN_EXE="windows/MonitorSwitcher.Win/bin/Release/net48/MonitorSwitcher.exe"
    cp "$WIN_EXE" "$BUILD_DIR/MonitorSwitcher.exe"
else
    echo "dotnet not found — skipping the Windows app (brew install dotnet)"
fi

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MonitorSwitcher" "$APP/Contents/MacOS/MonitorSwitcher"
cp Packaging/Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
cp "$BUILD_DIR/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
[[ -n "$WIN_EXE" ]] && cp "$WIN_EXE" "$APP/Contents/Resources/MonitorSwitcher.exe"
codesign --force --sign - --timestamp=none "$APP"

rm -f "$BUILD_DIR/MonitorSwitcher-macOS.zip"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/MonitorSwitcher-macOS.zip"
echo "Built $APP and $BUILD_DIR/MonitorSwitcher-macOS.zip"

if [[ "${1:-}" == "--install" ]]; then
    osascript -e "tell application id \"com.apajeb.MonitorSwitcher\" to quit" >/dev/null 2>&1 || true
    sleep 1
    pkill -x MonitorSwitcher >/dev/null 2>&1 || true
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" "/Applications/$APP_NAME.app"
    open "/Applications/$APP_NAME.app"
    echo "Installed to /Applications/$APP_NAME.app"
fi
