#!/bin/zsh
# Builds MeetingScribe.app into build/, signs it with the stable identity, optionally installs to /Applications.
set -euo pipefail
cd "${0:A:h}"
APP=build/MeetingScribe.app

# Nemotron 3 diarization model (FluidAudio Core ML port, `fast32` = 2.88 s streaming preset), bundled into the app
# so a meeting never downloads anything. Fetched once into build/models and pinned to one repo revision.
MODEL_REPO=FluidInference/nemotron-3-diarization-coreml
MODEL_REV=53445f72d5735e33406ccce7b92116bce7ab1ab7
MODEL_DIR=build/models/Nemotron3
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

swift build -c release --product MeetingScribe
BIN="$(swift build -c release --show-bin-path)/MeetingScribe"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MeetingScribe"
cp Info.plist "$APP/Contents/Info.plist"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
mkdir -p "$APP/Contents/Resources/Nemotron3"
cp -R "$MODEL_DIR/$BUNDLE" "$MODEL_DIR/learnable_sil_emb.bin" "$APP/Contents/Resources/Nemotron3/"
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
