#!/bin/zsh
# Builds MeetingScribe.app into build/, ad-hoc signs it, installs to ~/Applications.
set -euo pipefail
cd "${0:A:h}"
APP=build/MeetingScribe.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target arm64-apple-macos26.0 \
  -parse-as-library \
  -framework ScreenCaptureKit -framework Speech -framework AVFoundation -framework SwiftUI -framework AppKit \
  src/*.swift -o "$APP/Contents/MacOS/MeetingScribe"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ad-hoc (-) ties TCC grants to one exact binary; a stable identity keeps them across rebuilds.
codesign --force --deep --sign "${SIGN_ID:-ImageSmith Dev}" "$APP"
codesign --verify --verbose "$APP"
if [[ "${1:-}" == "--install" ]]; then
  mkdir -p ~/Applications
  rm -rf ~/Applications/MeetingScribe.app /Applications/MeetingScribe.app
  cp -R "$APP" /Applications/
  # Register with Launch Services and Spotlight so it shows up in Spotlight / Apps.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MeetingScribe.app
  mdimport /Applications/MeetingScribe.app
  echo "installed /Applications/MeetingScribe.app"
fi
