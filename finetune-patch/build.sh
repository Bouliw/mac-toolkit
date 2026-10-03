#!/bin/zsh
# Rebuilds FineTune (github.com/ronitsingh10/FineTune) without its audio device management:
# the default output and input stay under macOS control, FineTune only does per-app volume,
# EQ and routing. No Xcode needed, the Command Line Tools are enough.
# Installs the result in /Applications (the previous version is kept).
set -e
VERSION="v1.9.0"
HERE="${0:A:h}"
B="$HOME/Library/Application Support/mac-toolkit/finetune"   # keep it: the app reads a resource from here
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
xcode-select -p >/dev/null 2>&1 || { print "Command Line Tools required: xcode-select --install"; exit 1; }

print "· sources $VERSION and dependencies"
rm -rf "$B/src" "$B/deps"; mkdir -p "$B/deps"
git clone -q --depth 1 --branch "$VERSION" https://github.com/ronitsingh10/FineTune.git "$B/src" 2>/dev/null
git clone -q --depth 1 --branch 2.4.0 https://github.com/sindresorhus/KeyboardShortcuts "$B/deps/KeyboardShortcuts" 2>/dev/null
git clone -q --depth 1 --branch 1.5.1 https://github.com/wadetregaskis/FluidMenuBarExtra "$B/deps/FluidMenuBarExtra" 2>/dev/null

print "· patch and build (about 30 s)"
cd "$B/src"
/usr/bin/python3 "$HERE/patch.py" .
/usr/bin/python3 "$HERE/no_previews.py" FineTune "$B/deps/KeyboardShortcuts/Sources" "$B/deps/FluidMenuBarExtra/Sources"
cp "$HERE/Package.swift" Package.swift
swift build -c release 2>&1 | grep -E "error:|Build complete" || true
[ -x .build/release/FineTune ] || { print "Build failed"; exit 1; }

print "· app bundle"
# compiled assets (icons, colours) come from the official release
DMG="$B/FineTune-$VERSION.dmg"
[ -f "$DMG" ] || curl -fsSL -o "$DMG" "https://github.com/ronitsingh10/FineTune/releases/download/$VERSION/FineTune.dmg"
MNT=$(mktemp -d /tmp/finetune.XXXXXX)
yes | hdiutil attach -quiet -nobrowse -readonly -mountpoint "$MNT" "$DMG" >/dev/null
O="$MNT/FineTune.app/Contents"
APP="$B/FineTune.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/FineTune "$APP/Contents/MacOS/FineTune"
cp "$O/Info.plist" "$APP/Contents/Info.plist"
ditto "$O/Resources" "$APP/Contents/Resources"
[ -f "$O/PkgInfo" ] && cp "$O/PkgInfo" "$APP/Contents/"
hdiutil detach -quiet "$MNT"; rmdir "$MNT" 2>/dev/null || true
for k in SUFeedURL SUPublicEDKey SUEnableInstallerLauncherService SUEnableAutomaticChecks; do
  /usr/libexec/PlistBuddy -c "Delete :$k" "$APP/Contents/Info.plist" 2>/dev/null || true
done
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString ${VERSION#v}-patched" "$APP/Contents/Info.plist"
codesign --force --deep --sign - --entitlements FineTune/FineTune.entitlements "$APP" 2>/dev/null

print "· install"
osascript -e 'tell application "FineTune" to quit' >/dev/null 2>&1 || true
sleep 1; pkill -x FineTune || true
if [ -d /Applications/FineTune.app ]; then
  rm -rf "$B/FineTune-previous.app"; ditto /Applications/FineTune.app "$B/FineTune-previous.app"
fi
# the Homebrew cask would put the official build back on its next upgrade
brew list --cask finetune >/dev/null 2>&1 && brew uninstall --cask --quiet finetune >/dev/null 2>&1 || true
rm -rf /Applications/FineTune.app
ditto "$APP" /Applications/FineTune.app
open /Applications/FineTune.app
print "✓ patched FineTune installed; on first launch macOS asks again for the audio capture and Bluetooth permissions"
