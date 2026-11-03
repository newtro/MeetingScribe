#!/bin/zsh
# Resumable signed releases. Each phase exits; notarization is polled once by finish.
# usage: scripts/release.sh <prepare|submit|finish|publish|status> <major.minor.patch> [--retry]
set -euo pipefail
PHASE="${1:?usage: release.sh <prepare|submit|finish|publish|status> <version> [--retry]}"
VERSION="${2:?A major.minor.patch version is required.}"
RETRY="${3:-}"
[[ "$VERSION" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]] || { print -u2 'Version must look like 1.1.0.'; exit 2; }
[[ -z "$RETRY" || ( "$PHASE" == submit && "$RETRY" == --retry ) ]] || { print -u2 'Only submit accepts --retry.'; exit 2; }
ROOT="${0:A:h:h}"
REPO=newtro/MeetingScribe
TAG="v$VERSION"
OUT="$ROOT/build/releases/$VERSION"
SRC="$OUT/src"
STATE="$OUT/state.json"
KEY_ACCOUNT=meetingscribe
EXPECTED_KEY='RYVJhnnqxfds+aoVV43TEhr60r1xbdmc+yyTxYb4UQk='
mkdir -p "$OUT"
die() { print -u2 -- "$*"; exit 1; }
get() { python3 - "$STATE" "$1" <<'PY'
import json, pathlib, sys
p = pathlib.Path(sys.argv[1]); print(json.loads(p.read_text()).get(sys.argv[2], '') if p.exists() else '')
PY
}
put() { python3 - "$STATE" "$@" <<'PY'
import json, os, pathlib, sys, tempfile
p = pathlib.Path(sys.argv[1]); value = json.loads(p.read_text()) if p.exists() else {}
for i in range(2, len(sys.argv), 2): value[sys.argv[i]] = sys.argv[i + 1]
with tempfile.NamedTemporaryFile('w', dir=p.parent, delete=False) as f:
    json.dump(value, f, indent=2, sort_keys=True); f.write('\n'); f.flush(); os.fsync(f.fileno())
os.replace(f.name, p)
PY
}
clean_tracked() { [[ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ]] || die "Tracked changes in $1 must be committed first. Untracked planning files are not included."; }
clean_pinned_source() {
  [[ "$(git -C "$SRC" rev-parse HEAD)" == "$SHA" ]] || die 'Prepared source worktree moved.'
  [[ -z "$(git -C "$SRC" status --porcelain --untracked-files=all)" ]] || die 'Pinned worktree has changed or contains untracked source. Only ignored build outputs may be present.'
}
remote_main() { git -C "$ROOT" ls-remote origin refs/heads/main | awk '{print $1}'; }
check_origin() {
  local remote="$(git -C "$ROOT" remote get-url origin)"
  [[ "$remote" == "https://github.com/$REPO.git" || "$remote" == "https://github.com/$REPO" || "$remote" == "git@github.com:$REPO.git" ]] || die 'Unexpected origin repository.'
}
require_state() {
  [[ -f "$STATE" && "$(get version)" == "$VERSION" ]] || die 'Run prepare for this version first.'
  SHA="$(get source)"; BUILD_NUMBER="$(get build)"
  [[ "$SHA" =~ '^[a-f0-9]{40}$' && "$BUILD_NUMBER" =~ '^[1-9][0-9]*$' ]] || die 'Invalid release state.'
}
signing_tools() {
  SPARKLE_BIN="$SRC/.build/artifacts/sparkle/Sparkle/bin"
  [[ -x "$SPARKLE_BIN/sign_update" ]] || die 'Sparkle signing tools missing from prepared worktree.'
  [[ "$("$SPARKLE_BIN/generate_keys" --account "$KEY_ACCOUNT" -p)" == "$EXPECTED_KEY" ]] || die 'Sparkle public key does not match the app. No key was generated or exported.'
}
case "$PHASE" in
prepare)
  check_origin; clean_tracked "$ROOT"
  SHA="$(git -C "$ROOT" rev-parse HEAD)"; BUILD_NUMBER="$(git -C "$ROOT" rev-list --count "$SHA")"
  if [[ -f "$STATE" ]]; then
    [[ "$(get source)" == "$SHA" ]] || die 'This version is pinned to another commit. Resume it or choose a new version; artifacts are not overwritten.'
    [[ "$(get prepared)" != yes ]] || { print "Already prepared $VERSION from $SHA"; exit 0; }
  else
    [[ -z "$(git -C "$ROOT" ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}")" ]] || die 'This release tag already exists.'
    if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then die 'This release version already exists.'; fi
    put version "$VERSION" source "$SHA" build "$BUILD_NUMBER" nonce "$(uuidgen)"
  fi
  if [[ ! -d "$SRC" ]]; then git -C "$ROOT" worktree add --detach "$SRC" "$SHA"; fi
  clean_pinned_source
  python3 "$SRC/scripts/appcast.py" "$SRC/appcast.xml" --check-build "$BUILD_NUMBER"
  print "Building $VERSION ($BUILD_NUMBER) from $SHA"
  (cd "$SRC" && VERSION="$VERSION" BUILD_NUMBER="$BUILD_NUMBER" \
      SIGN_ID="${MEETINGSCRIBE_DEVELOPMENT_SIGN_ID:-Apple Development: scott@johnnycode.ai (52XDFWFDBZ)}" \
      MEETINGSCRIBE_MODEL_CACHE="${MEETINGSCRIBE_MODEL_CACHE:-$ROOT/build/models}" ./build.sh >"$OUT/build.log" 2>&1) || die "Build failed; see $OUT/build.log"
  "$SRC/build/MeetingScribe.app/Contents/MacOS/MeetingScribe" --workflowtest --out "$OUT/verification" >"$OUT/test.log" 2>&1 || die "Workflow checks failed; see $OUT/test.log"
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$SRC/build/MeetingScribe.app/Contents/Info.plist")" == "$VERSION" ]] || die 'Build has the wrong marketing version.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$SRC/build/MeetingScribe.app/Contents/Info.plist")" == "$BUILD_NUMBER" ]] || die 'Build has the wrong monotonic build number.'
  signing_tools
  put prepared yes
  print "Prepared. Next: scripts/release.sh submit $VERSION"
  ;;
submit)
  require_state
  [[ "$(get prepared)" == yes ]] || die 'Preparation is incomplete.'
  clean_pinned_source
  [[ "$(get submitted)" != yes ]] || { print 'Already submitted. Use finish to poll notarization.'; exit 0; }
  if [[ "$(get submissionStarted)" == yes && "$RETRY" != --retry ]]; then
    die 'A submission was attempted. Try finish first; if upload failed, use submit VERSION --retry explicitly.'
  fi
  put submissionStarted yes
  "$SRC/scripts/developer-id.sh" "$SRC/build/MeetingScribe.app" "$OUT/signing" upload
  put submitted yes
  print "Submitted. Later run: scripts/release.sh finish $VERSION"
  ;;
finish)
  require_state
  [[ "$(get submissionStarted)" == yes ]] || die 'Submit for notarization first.'
  [[ "$(get packaged)" != yes ]] || { print 'Already packaged; use publish when ready.'; exit 0; }
  APP="$OUT/notarized/MeetingScribe.app"
  if [[ "$(get notarized)" != yes ]]; then
    NOTARIZED_ATTEMPT="$OUT/notarized-$(uuidgen | tr '[:upper:]' '[:lower:]')"
    if ! xcodebuild -exportNotarizedApp -archivePath "$OUT/signing/MeetingScribe.xcarchive" -exportPath "$NOTARIZED_ATTEMPT" >"$OUT/notarize.log" 2>&1; then
      if grep -qiE 'invalid|rejected|not (be )?notarized' "$OUT/notarize.log"; then die "Notarization failed; inspect $OUT/notarize.log"; fi
      print "Notarization/export not ready. Inspect $OUT/notarize.log; run finish again later."
      exit 75
    fi
    APP="$NOTARIZED_ATTEMPT/MeetingScribe.app"
  fi
  codesign --verify --deep --strict "$APP"
  python3 "$SRC/scripts/verify-audio-input.py" "$APP"
  SIGNING_INFO="$(codesign -dvv "$APP" 2>&1)"
  [[ "$SIGNING_INFO" == *'Authority=Developer ID Application:'* && "$SIGNING_INFO" == *'TeamIdentifier=232A77467G'* && "$SIGNING_INFO" == *'(runtime)'* ]] || die 'Expected hardened Developer ID release signing identity.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")" == "$VERSION" ]] || die 'Notarized app marketing version differs from pinned release.'
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")" == "$BUILD_NUMBER" ]] || die 'Notarized app build number differs from pinned release.'
  spctl --assess --type execute "$APP"
  xcrun stapler validate "$APP"
  if [[ "$(get notarized)" != yes ]]; then
    # A partial failed export is never promoted or treated as success merely because it exists.
    python3 - "$OUT/notarized" "$NOTARIZED_ATTEMPT" <<'PY'
import os, pathlib, sys, uuid
link = pathlib.Path(sys.argv[1]); temporary = link.with_name('.notarized-' + str(uuid.uuid4()))
if link.exists() and not link.is_symlink():
    os.rename(link, link.with_name('notarized-unverified-' + str(uuid.uuid4())))
os.symlink(sys.argv[2], temporary)
os.replace(temporary, link)
PY
    put notarized yes
    APP="$OUT/notarized/MeetingScribe.app"
  fi
  ZIP="$OUT/MeetingScribe-$VERSION.zip"; DMG="$OUT/MeetingScribe-$VERSION.dmg"
  # Final artifact names are only created after the packaging command succeeds.
  if [[ ! -f "$ZIP" ]]; then ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP.partial"; mv "$ZIP.partial" "$ZIP"; fi
  if [[ ! -f "$DMG" ]]; then
    mkdir -p "$OUT/dmg"
    [[ -d "$OUT/dmg/MeetingScribe.app" ]] || ditto "$APP" "$OUT/dmg/MeetingScribe.app"
    [[ -L "$OUT/dmg/Applications" ]] || ln -s /Applications "$OUT/dmg/Applications"
    hdiutil create -quiet -volname "MeetingScribe $VERSION" -srcfolder "$OUT/dmg" -format UDZO "$OUT/MeetingScribe-$VERSION-pending.dmg"
    mv "$OUT/MeetingScribe-$VERSION-pending.dmg" "$DMG"
  fi
  signing_tools
  SIGNATURE="$("$SPARKLE_BIN/sign_update" --account "$KEY_ACCOUNT" "$ZIP")"
  MIN_OS="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$APP/Contents/Info.plist")"
  if [[ -f "$SRC/appcast.xml" ]]; then cp "$SRC/appcast.xml" "$OUT/appcast.xml"; fi
  python3 "$SRC/scripts/appcast.py" "$OUT/appcast.xml" --version "$VERSION" --build "$BUILD_NUMBER" --min-os "$MIN_OS" \
    --url "https://github.com/$REPO/releases/download/$TAG/MeetingScribe-$VERSION.zip" --signature "$SIGNATURE" \
    --notes "https://github.com/$REPO/releases/tag/$TAG"
  put zipSHA "$(shasum -a 256 "$ZIP" | awk '{print $1}')" dmgSHA "$(shasum -a 256 "$DMG" | awk '{print $1}')" \
    appcastSHA "$(shasum -a 256 "$OUT/appcast.xml" | awk '{print $1}')" packaged yes
  print "Signed, notarized packages ready in $OUT. Next: scripts/release.sh publish $VERSION"
  ;;
publish)
  require_state; check_origin
  [[ "$(get published)" != yes ]] || { print "Already published: https://github.com/$REPO/releases/tag/$TAG"; exit 0; }
  [[ "$(get packaged)" == yes ]] || die 'Finish notarization and packaging first.'
  FEED_COMMIT="$(get feedCommit)"; REMOTE="$(remote_main)"
  if [[ -n "$FEED_COMMIT" && "$REMOTE" == "$FEED_COMMIT" ]]; then put published yes; print 'Release and appcast already published.'; exit 0; fi
  clean_tracked "$ROOT"
  [[ "$(git -C "$ROOT" rev-parse HEAD)" == "$SHA" && "$REMOTE" == "$SHA" ]] || die 'Publish requires the pinned source commit to equal current HEAD and remote main. No feed was changed.'
  [[ "$(gh repo view "$REPO" --json visibility -q .visibility)" == PUBLIC ]] || die 'Installed copies require a public appcast and downloads.'
  ZIP="$OUT/MeetingScribe-$VERSION.zip"; DMG="$OUT/MeetingScribe-$VERSION.dmg"
  [[ "$(shasum -a 256 "$ZIP" | awk '{print $1}')" == "$(get zipSHA)" && "$(shasum -a 256 "$DMG" | awk '{print $1}')" == "$(get dmgSHA)" ]] || die 'Packaged artifact changed; refusing publication.'
  [[ "$(shasum -a 256 "$OUT/appcast.xml" | awk '{print $1}')" == "$(get appcastSHA)" ]] || die 'Packaged appcast changed; refusing publication.'
  MARKER="<!-- MeetingScribe release $(get nonce) source $SHA -->"
  printf 'Download MeetingScribe-%s.dmg for a first install. Installed copies check for signed updates automatically.\n\n%s\n' "$VERSION" "$MARKER" >"$OUT/release-notes.md"
  if ! gh release view "$TAG" --repo "$REPO" --json body,targetCommitish,isDraft,assets,url >"$OUT/github-release.json" 2>/dev/null; then
    [[ -z "$(git -C "$ROOT" ls-remote origin "refs/tags/$TAG" "refs/tags/$TAG^{}")" ]] || die 'Release tag already exists outside this run.'
    gh release create "$TAG" --repo "$REPO" --target "$SHA" --draft --title "MeetingScribe $VERSION" --notes-file "$OUT/release-notes.md"
    gh release view "$TAG" --repo "$REPO" --json body,targetCommitish,isDraft,assets,url >"$OUT/github-release.json"
  fi
  python3 - "$OUT/github-release.json" "$MARKER" "$SHA" <<'PY'
import json, sys
r = json.load(open(sys.argv[1]))
if sys.argv[2] not in r['body'] or r['targetCommitish'] != sys.argv[3]:
    sys.exit('Version already exists outside this release run; refusing to overwrite it.')
PY
  # No --clobber: retries verify existing assets, never replace them.
  for asset in "$ZIP" "$DMG"; do
    name="${asset:t}"
    if gh release view "$TAG" --repo "$REPO" --json assets --jq '.assets[].name' | grep -Fxq "$name"; then
      VERIFY="$OUT/verify-assets"; mkdir -p "$VERIFY"
      [[ -f "$VERIFY/$name" ]] || gh release download "$TAG" --repo "$REPO" --pattern "$name" --dir "$VERIFY"
      [[ "$(shasum -a 256 "$VERIFY/$name" | awk '{print $1}')" == "$(shasum -a 256 "$asset" | awk '{print $1}')" ]] || die "Existing remote asset differs: $name"
    else
      gh release upload "$TAG" "$asset" --repo "$REPO"
    fi
  done
  gh release edit "$TAG" --repo "$REPO" --draft=false
  put releasePublished yes
  FEED_SRC="$OUT/feed-source"
  if [[ -z "$FEED_COMMIT" ]]; then
    [[ -d "$FEED_SRC" ]] || git -C "$ROOT" worktree add --detach "$FEED_SRC" "$SHA"
    if [[ "$(git -C "$FEED_SRC" rev-parse HEAD)" == "$SHA" ]]; then
      cp "$OUT/appcast.xml" "$FEED_SRC/appcast.xml"
      git -C "$FEED_SRC" add -- appcast.xml
      git -C "$FEED_SRC" commit -m "Publish MeetingScribe $VERSION update feed" -- appcast.xml
    else
      # Recover a crash after committing the feed but before recording the commit receipt.
      [[ "$(git -C "$FEED_SRC" rev-parse HEAD^)" == "$SHA" && "$(git -C "$FEED_SRC" diff --name-only HEAD^ HEAD)" == appcast.xml ]] || die 'Feed worktree moved unexpectedly.'
      cmp -s "$OUT/appcast.xml" "$FEED_SRC/appcast.xml" || die 'Feed worktree differs from the packaged feed.'
    fi
    FEED_COMMIT="$(git -C "$FEED_SRC" rev-parse HEAD)"; put feedCommit "$FEED_COMMIT"
  fi
  [[ "$(remote_main)" == "$SHA" ]] || die 'Remote main moved; release exists but feed remains unpublished. Do not force-push.'
  git -C "$ROOT" push origin "${FEED_COMMIT}:refs/heads/main"
  put published yes
  print "Published https://github.com/$REPO/releases/tag/$TAG"
  print 'Only appcast.xml was committed by the publication step. Your checkout remains at its source commit.'
  ;;
status)
  [[ -f "$STATE" ]] || die 'No state for this version.'
  cat "$STATE"
  ;;
*) die 'Phase must be prepare, submit, finish, publish or status.' ;;
esac
