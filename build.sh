#!/bin/zsh
# Builds MeetingScribe.app into build/, signs it with the stable identity, optionally installs to /Applications.
set -euo pipefail
cd "${0:A:h}"
APP=build/MeetingScribe.app
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD)}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { echo "VERSION must be X.Y.Z" >&2; exit 2; }
[[ "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || { echo "BUILD_NUMBER must be a positive integer" >&2; exit 2; }
[[ "${SIGN_ID:-ImageSmith Dev}" != "-" ]] || { echo "A stable signing identity is required; ad-hoc signing revokes capture permissions." >&2; exit 2; }
SPEECH_CACHE="${MEETINGSCRIBE_MODEL_CACHE:-build/models}"

# Nemotron 3 diarization model (FluidAudio Core ML port, `fast32` = 2.88 s streaming preset), bundled into the app
# so a meeting never downloads anything. Fetched once into build/models and pinned to one repo revision.
MODEL_REPO=FluidInference/nemotron-3-diarization-coreml
MODEL_REV=53445f72d5735e33406ccce7b92116bce7ab1ab7
MODEL_DIR="$SPEECH_CACHE/Nemotron3"
BUNDLE=Nemotron3Diarizer_fast32.mlmodelc
if [[ ! -f "$MODEL_DIR/.rev-$MODEL_REV-$BUNDLE" ]]; then
  echo "fetching $BUNDLE ($MODEL_REPO@${MODEL_REV:0:8}, ~200 MB)…"
  rm -rf "$MODEL_DIR"
  for f in learnable_sil_emb.bin \
           monolithic/$BUNDLE/coremldata.bin \
           monolithic/$BUNDLE/analytics/coremldata.bin \
           monolithic/$BUNDLE/model.mil \
           monolithic/$BUNDLE/weights/weight.bin; do
    dest="$MODEL_DIR/${f#monolithic/}"
    mkdir -p "${dest:h}"
    curl -fsSL --retry 3 -o "$dest" "https://huggingface.co/$MODEL_REPO/resolve/$MODEL_REV/$f"
  done
  touch "$MODEL_DIR/.rev-$MODEL_REV-$BUNDLE"
fi

# The 640 ms int8 encoder and shared decoder/joint only (~610 MB); all files verified against
# the immutable repository's Git/LFS digests. No runtime downloads or alternate tier bundles.
UNIFIED_DIR="$SPEECH_CACHE/UnifiedSpeech"
python3 scripts/fetch-unified-speech.py "$UNIFIED_DIR"

swift build -c release --product MeetingScribe
BIN="$(swift build -c release --show-bin-path)/MeetingScribe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN" "$APP/Contents/MacOS/MeetingScribe"
cp Info.plist "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
ditto "${BIN:h}/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Ship redistribution terms and attribution with the SDKs and bundled model weights.
ditto Resources/ThirdPartyNotices "$APP/Contents/Resources/ThirdPartyNotices"
mkdir -p "$APP/Contents/Resources/Nemotron3"
cp -R "$MODEL_DIR/$BUNDLE" "$MODEL_DIR/learnable_sil_emb.bin" "$APP/Contents/Resources/Nemotron3/"
cp -R "$UNIFIED_DIR" "$APP/Contents/Resources/UnifiedSpeech"
# Ad-hoc (-) ties TCC grants to one exact binary; a stable identity keeps them across rebuilds.
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
# The self-signed local identity has no Apple Team ID; hardened library validation
# cannot load its embedded frameworks. Release preparation uses Apple Development,
# then Xcode re-signs the archive with Developer ID and retains hardened runtime.
SIGN_OPTIONS=()
[[ "${SIGN_ID:-ImageSmith Dev}" != "ImageSmith Dev" ]] && SIGN_OPTIONS=(--options runtime)
sign() { codesign --force "${SIGN_OPTIONS[@]}" --timestamp=none --sign "${SIGN_ID:-ImageSmith Dev}" "$@"; }
for xpc in "$SPARKLE"/XPCServices/*.xpc; do sign "$xpc"; done
sign "$SPARKLE/Autoupdate"
sign "$SPARKLE/Updater.app"
sign "$APP/Contents/Frameworks/Sparkle.framework"
sign --entitlements MeetingScribe.entitlements "$APP"
codesign --verify --verbose "$APP"
python3 scripts/verify-audio-input.py "$APP"
if [[ "${1:-}" == "--install" ]]; then
  if pgrep -x MeetingScribe >/dev/null; then
    echo "Quit MeetingScribe normally before installing; recording must finish and flush first." >&2
    exit 1
  fi
  if codesign -dvv /Applications/MeetingScribe.app 2>&1 | /usr/bin/grep -q 'Authority=Developer ID Application'; then
    echo "Preserving the installed Developer ID signing identity…"
    scripts/developer-id.sh "$PWD/$APP" "$PWD/build/install-signing" export
    rm -rf "$APP"
    ditto "$PWD/build/install-signing/export/MeetingScribe.app" "$APP"
  fi
  mkdir -p ~/Applications
  rm -rf ~/Applications/MeetingScribe.app /Applications/MeetingScribe.app
  cp -R "$APP" /Applications/
  python3 scripts/verify-audio-input.py /Applications/MeetingScribe.app
  # Register with Launch Services and Spotlight so it shows up in Spotlight / Apps.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f /Applications/MeetingScribe.app
  mdimport /Applications/MeetingScribe.app
  echo "installed /Applications/MeetingScribe.app"
fi
