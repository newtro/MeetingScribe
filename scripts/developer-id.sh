#!/bin/zsh
# Sign a built app with Xcode's cloud-managed Developer ID certificate. No key export.
# usage: developer-id.sh <MeetingScribe.app> <work directory> [export|upload]
set -euo pipefail
APP="${1:?usage: developer-id.sh <app> <work directory> [export|upload]}"
WORK="${2:?usage: developer-id.sh <app> <work directory> [export|upload]}"
DEST="${3:-export}"
[[ "$DEST" == export || "$DEST" == upload ]] || { print -u2 'Destination must be export or upload.'; exit 2; }
APP="${APP:A}"; WORK="${WORK:A}"
[[ -f "$APP/Contents/Info.plist" ]] || { print -u2 'App bundle is missing.'; exit 1; }
mkdir -p "$WORK"
WORK_BASE="$WORK"
# Local installs reuse the work directory with new binaries; their export is a fresh attempt.
# Notarization uploads instead retain one immutable archive so finish can poll it later.
if [[ "$DEST" == export ]]; then
  [[ ! -e "$WORK_BASE/export" || -L "$WORK_BASE/export" ]] || { print -u2 'Existing export is not a managed symlink; use a fresh work directory.'; exit 1; }
  WORK="$WORK_BASE/attempt-$(uuidgen | tr '[:upper:]' '[:lower:]')"
  mkdir -p "$WORK"
fi
ARCHIVE="$WORK/MeetingScribe.xcarchive"
codesign --verify --deep --strict "$APP"

# Preserve the archive across notarization polls/retries. Never rebuild it from a newer app.
python3 - "$APP" "$WORK" <<'PY'
import datetime, hashlib, json, pathlib, plistlib, sys
app, work = map(pathlib.Path, sys.argv[1:])
info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
if info['CFBundleIdentifier'] != 'com.trellispoint.meetingscribe':
    sys.exit('Unexpected bundle identity.')
files = ['Contents/MacOS/MeetingScribe', 'Contents/Info.plist', 'Contents/_CodeSignature/CodeResources']
receipt = {name: hashlib.sha256((app / name).read_bytes()).hexdigest() for name in files}
source = work / 'archive-source.json'
archive = work / 'MeetingScribe.xcarchive'
if source.exists():
    if json.loads(source.read_text()) != receipt:
        sys.exit('Archive source changed. Use a new release/work directory; the existing archive is preserved.')
elif archive.exists():
    sys.exit('Archive exists without its source receipt; refusing to replace it.')
else:
    source.write_text(json.dumps(receipt, indent=2) + '\n')
if not (archive / 'Info.plist').exists():
    archive.mkdir(exist_ok=True)
    metadata = {
        'ArchiveVersion': 2, 'CreationDate': datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None),
        'Name': 'MeetingScribe', 'SchemeName': 'MeetingScribe',
        'ApplicationProperties': {'ApplicationPath': 'Applications/MeetingScribe.app',
            'CFBundleIdentifier': info['CFBundleIdentifier'],
            'CFBundleShortVersionString': info['CFBundleShortVersionString'],
            'CFBundleVersion': info['CFBundleVersion'], 'Architectures': ['arm64'], 'Team': '232A77467G'}}
    (archive / 'Info.plist').write_bytes(plistlib.dumps(metadata))
PY
if [[ ! -d "$ARCHIVE/Products/Applications/MeetingScribe.app" ]]; then
  mkdir -p "$ARCHIVE/Products/Applications"
  # Only this private partial path is replaced after an interrupted copy.
  rm -rf "$ARCHIVE/Products/Applications/MeetingScribe.app.partial"
  ditto "$APP" "$ARCHIVE/Products/Applications/MeetingScribe.app.partial"
  mv "$ARCHIVE/Products/Applications/MeetingScribe.app.partial" "$ARCHIVE/Products/Applications/MeetingScribe.app"
fi
if [[ ! -f "$WORK/archive-hardened" ]]; then
  DEVELOPMENT_ID="${MEETINGSCRIBE_DEVELOPMENT_SIGN_ID:-Apple Development: scott@johnnycode.ai (52XDFWFDBZ)}"
  # A self-signed hardened app cannot load Sparkle under library validation. Give every nested
  # code object the same Apple Development team before Xcode's cloud Developer ID export.
  python3 - "$ARCHIVE/Products/Applications/MeetingScribe.app" "$DEVELOPMENT_ID" <<'PY'
import pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1]); identity = sys.argv[2]
magic = {bytes.fromhex(h) for h in ['feedface', 'feedfacf', 'cefaedfe', 'cffaedfe', 'cafebabe', 'bebafeca', 'cafebabf', 'bfbafeca']}
binaries, bundles = [], []
for path in root.rglob('*'):
    if path.is_symlink(): continue
    if path.is_file():
        with path.open('rb') as f:
            if f.read(4) in magic: binaries.append(path)
    elif path.suffix in {'.app', '.xpc', '.framework'}: bundles.append(path)
for path in sorted(binaries, key=lambda p: len(p.parts), reverse=True) + sorted(bundles, key=lambda p: len(p.parts), reverse=True) + [root]:
    subprocess.run(['codesign', '--force', '--options', 'runtime', '--sign', identity,
                    '--preserve-metadata=entitlements', str(path)], check=True)
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(root)], check=True)
PY
  touch "$WORK/archive-hardened"
fi
python3 - "$WORK/ExportOptions-$DEST.plist" "$DEST" <<'PY'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({'method': 'developer-id', 'destination': sys.argv[2],
    'signingStyle': 'automatic', 'teamID': '232A77467G'}))
PY
ATTEMPT="$(uuidgen | tr '[:upper:]' '[:lower:]')"
OUTPUT="$WORK/$DEST-$ATTEMPT"
LOG="$WORK/$DEST-$ATTEMPT.log"
if ! xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$OUTPUT" \
     -exportOptionsPlist "$WORK/ExportOptions-$DEST.plist" -allowProvisioningUpdates >"$LOG" 2>&1; then
  print -u2 "Xcode $DEST failed; archive retained. Inspect $LOG."
  exit 1
fi
if [[ "$DEST" == export ]]; then
  codesign --verify --deep --strict "$OUTPUT/MeetingScribe.app"
  SIGNING_INFO="$(codesign -dvv "$OUTPUT/MeetingScribe.app" 2>&1)"
  [[ "$SIGNING_INFO" == *'Authority=Developer ID Application:'* && "$SIGNING_INFO" == *'TeamIdentifier=232A77467G'* && "$SIGNING_INFO" == *'(runtime)'* ]] || {
    print -u2 'Export did not have the expected hardened Developer ID identity.'; exit 1;
  }
  python3 - "$WORK_BASE/export" "$OUTPUT" <<'PY'
import os, pathlib, sys, uuid
link = pathlib.Path(sys.argv[1]); temporary = link.with_name('.export-' + str(uuid.uuid4()))
os.symlink(sys.argv[2], temporary)
os.replace(temporary, link)
PY
fi
python3 - "$WORK/last-$DEST.json" "$OUTPUT" "$LOG" <<'PY'
import json, os, pathlib, sys, tempfile
path = pathlib.Path(sys.argv[1])
with tempfile.NamedTemporaryFile('w', dir=path.parent, delete=False) as f:
    json.dump({'output': sys.argv[2], 'log': sys.argv[3]}, f, indent=2); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(f.name, path)
PY
print "Xcode $DEST completed: $OUTPUT"
