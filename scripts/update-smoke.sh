#!/bin/zsh
# A real automatic Sparkle download/install-on-quit, isolated from the installed app and all user data.
# Uses a tiny native host and synthetic transcript files. This tests Sparkle packaging/install, not
# MeetingScribe's busy-meeting policy or production notarization; those have separate checks.
set -euo pipefail
umask 077
ROOT="${0:A:h:h}"
cd "$ROOT"
RUN="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OUT="$ROOT/build/update-smoke/$RUN"
ID="com.trellispoint.meetingscribe.updatetest.$RUN"
SPARKLE_DIST="${SPARKLE_DIST:-$ROOT/.build/artifacts/sparkle/Sparkle}"
# Hardened runtime requires an Apple team identity for framework library validation.
SIGN_ID="${SPARKLE_TEST_SIGN_ID:-$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development:.*\)"/\1/p' | head -1)}"
[[ -n "$SIGN_ID" ]] || { echo 'Set SPARKLE_TEST_SIGN_ID to an Apple Development identity.' >&2; exit 1; }
FRAMEWORK="$SPARKLE_DIST/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || { echo 'Build the app once to obtain Sparkle.' >&2; exit 1; }
mkdir -p "$OUT/feed" "$OUT/reports" "$OUT/install"
SERVER_PID=""; HOST_PID=""
cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  [[ -n "$HOST_PID" ]] && kill "$HOST_PID" 2>/dev/null || true
  defaults delete "$ID" >/dev/null 2>&1 || true
  rm -f "$OUT/throwaway.pem" "$OUT/throwaway-private.b64"
  local LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
  "$LSREG" -u "$OUT/install/UpdateSmoke.app" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT TERM HUP
python3 tests/update-smoke/server.py "$OUT/feed" "$OUT/port" > "$OUT/http.log" 2>&1 &
SERVER_PID=$!
for attempt in {1..100}; do [[ -f "$OUT/port" ]] && break; sleep 0.1; done
PORT="$(cat "$OUT/port")"
# A newly generated test-only seed; never reads or exports the production Keychain key.
openssl genpkey -algorithm ed25519 -out "$OUT/throwaway.pem"
openssl pkey -in "$OUT/throwaway.pem" -outform DER | tail -c 32 | base64 > "$OUT/throwaway-private.b64"
PUBLIC_KEY="$(openssl pkey -in "$OUT/throwaway.pem" -pubout -outform DER | tail -c 32 | base64)"
swiftc -swift-version 5 -parse-as-library -F "${FRAMEWORK:h}" -framework Sparkle \
  -Xlinker -rpath -Xlinker @executable_path/../Frameworks tests/update-smoke/UpdateSmokeHost.swift -o "$OUT/UpdateSmoke" > "$OUT/compile.log" 2>&1 \
  || { cat "$OUT/compile.log"; exit 1; }
for phase in A B; do
  version=9.0.0; number=9000
  [[ "$phase" == B ]] && { version=9.0.1; number=9001; }
  APP="$OUT/$phase/UpdateSmoke.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks"
  cp "$OUT/UpdateSmoke" "$APP/Contents/MacOS/UpdateSmoke"
  ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
  python3 - "$APP/Contents/Info.plist" "$ID" "$version" "$number" "$PORT" "$PUBLIC_KEY" "$OUT/reports" <<'PY'
import plistlib,sys
path,bundle,version,number,port,key,out=sys.argv[1:]
with open(path,'wb') as f: plistlib.dump({
 'CFBundleIdentifier':bundle,'CFBundleName':'UpdateSmoke','CFBundleExecutable':'UpdateSmoke',
 'CFBundlePackageType':'APPL','CFBundleVersion':number,'CFBundleShortVersionString':version,
 'LSMinimumSystemVersion':'14.0','LSUIElement':True,'SmokeOutput':out,
 'SUFeedURL':f'http://127.0.0.1:{port}/appcast.xml','SUPublicEDKey':key,
 'SUEnableAutomaticChecks':True,'SUAutomaticallyUpdate':True,'SUVerifyUpdateBeforeExtraction':True,
 'NSAppTransportSecurity':{'NSAllowsLocalNetworking':True}},f)
PY
  NESTED="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
  sign() { codesign --force --options runtime --timestamp=none --sign "$SIGN_ID" "$@" >> "$OUT/sign.log" 2>&1; }
  for xpc in "$NESTED"/XPCServices/*.xpc; do sign "$xpc"; done
  sign "$NESTED/Autoupdate"; sign "$NESTED/Updater.app"; sign "$APP/Contents/Frameworks/Sparkle.framework"; sign "$APP"
done
ditto -c -k --sequesterRsrc --keepParent "$OUT/B/UpdateSmoke.app" "$OUT/feed/update.zip"
SIGNATURE="$("$SPARKLE_DIST/bin/sign_update" --ed-key-file "$OUT/throwaway-private.b64" "$OUT/feed/update.zip")"
cat > "$OUT/feed/appcast.xml" <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle"><channel><title>Isolated update smoke</title><item><title>9.0.1</title><sparkle:version>9001</sparkle:version><sparkle:shortVersionString>9.0.1</sparkle:shortVersionString><sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion><enclosure url="http://127.0.0.1:$PORT/update.zip" $SIGNATURE type="application/octet-stream"/></item></channel></rss>
XML
ditto "$OUT/A/UpdateSmoke.app" "$OUT/install/UpdateSmoke.app"
BIN="$OUT/install/UpdateSmoke.app/Contents/MacOS/UpdateSmoke"
"$BIN" > "$OUT/host-A.log" 2>&1 &
HOST_PID=$!
for attempt in {1..180}; do
  [[ -f "$OUT/reports/9.0.0-error.json" ]] && { cat "$OUT/reports/9.0.0-error.json"; exit 1; }
  if ! kill -0 "$HOST_PID" 2>/dev/null && [[ ! -f "$OUT/reports/9.0.0-install-on-quit.json" ]]; then
    cat "$OUT/host-A.log"; echo "Test host exited before scheduling its update." >&2; exit 1
  fi
  CURRENT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$OUT/install/UpdateSmoke.app/Contents/Info.plist" 2>/dev/null || true)"
  [[ "$CURRENT" == 9001 ]] && break
  sleep 0.5
done
[[ "$CURRENT" == 9001 ]] || { echo "Update did not replace build 9000; see $OUT"; exit 1; }
wait "$HOST_PID" || true; HOST_PID=""
codesign --verify --deep --strict "$OUT/install/UpdateSmoke.app" > "$OUT/verify.log" 2>&1
"$BIN" > "$OUT/host-B.log" 2>&1 &
HOST_PID=$!
for attempt in {1..80}; do [[ -f "$OUT/reports/9.0.1-verified.json" ]] && break; sleep 0.25; done
wait "$HOST_PID" || true; HOST_PID=""
python3 - "$OUT" <<'PY'
import json,sys
from pathlib import Path
root=Path(sys.argv[1]); report=json.loads((root/'reports/9.0.1-verified.json').read_text())
assert report['unchanged'], report
assert (root/'reports/9.0.0-install-on-quit.json').exists()
report.update(passed=True,check='signed archive automatically downloaded and installed on quit; synthetic JSONL/text unchanged',productionDataTouched=False)
(root/'result.json').write_text(json.dumps(report,indent=2))
print('PASS:',root/'result.json')
PY
