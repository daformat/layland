#!/bin/bash
# Builds, packages, notarizes and staples a DMG, and publishes the release that every
# installed copy updates from. Adapted from Subtitles' release.sh.
#
# Prerequisites, one-time:
#   - a "Developer ID Application" certificate in the login keychain
#   - notarization credentials stored as a keychain profile (Subtitles' works as is):
#       xcrun notarytool store-credentials "subtitles-notary" \
#         --apple-id <you@example.com> --team-id <TEAMID> --password <app-specific>
#   - the Sparkle signing key in the login keychain, whose public half is SUPublicEDKey in
#     project.yml. Back it up (generate_keys -x): lose it and every installed copy refuses
#     every future update.
#   - `gh`, logged in, and xcodegen
#
# The GitHub release is the download. Three assets: the DMG under the stable name
# Layland.dmg (so releases/latest/download/Layland.dmg is a permanent link), the zip
# Sparkle installs from, and appcast.xml, which the app reads through
# releases/latest/download/appcast.xml. The release is created as a draft and published
# only once every asset is up, so no check sees an appcast whose zip is still uploading.
#
#   ./release.sh                 the real thing
#   ./release.sh --no-notarize   build the DMG and stop (NOT shippable)
#   ./release.sh --dry-run       the publishing half against a draft it deletes again
#   ./release.sh --critical      mark the update critical (no Skip)
set -euo pipefail

cd "$(dirname "$0")"
PROFILE="${LAYLAND_NOTARY_PROFILE:-subtitles-notary}"

NOTARIZE=yes
CRITICAL=no
DRYRUN=no
for arg in "$@"; do
  case "$arg" in
    --no-notarize) NOTARIZE=no ;;
    --critical) CRITICAL=yes ;;
    --dry-run) DRYRUN=yes; NOTARIZE=no ;;
    *) echo "usage: release.sh [--no-notarize | --dry-run] [--critical]" >&2; exit 1 ;;
  esac
done

setting() { grep -m1 "^ *$1:" project.yml | sed -E 's/^[^:]*: *"?([^"]*)"?.*$/\1/'; }
VERSION=$(setting MARKETING_VERSION)
BUILD=$(setting CURRENT_PROJECT_VERSION)
FEED_URL=$(setting SUFeedURL)

DERIVED="build/DerivedData"
BUILT_APP="$DERIVED/Build/Products/Release/Layland.app"
OUT="build/release"
APP="$OUT/Layland.app"
STAGE="$OUT/dmg"
DMG="$OUT/Layland-$VERSION.dmg"
STABLE_DMG="$OUT/Layland.dmg"
ZIP="$OUT/Layland-$VERSION.zip"
FEED_DIR="$OUT/feed"
GENERATE_APPCAST="$DERIVED/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast"
REPO="daformat/layland"
RELEASES="https://github.com/$REPO/releases"
TAG="v$VERSION"

echo "==> release $VERSION (build $BUILD)"

# Everything the tail needs, checked before the notarization round trip.
if [ "$NOTARIZE" = yes ] || [ "$DRYRUN" = yes ]; then
  command -v gh >/dev/null || { echo "!! gh is not installed" >&2; exit 1; }
  gh auth status >/dev/null 2>&1 || { echo "!! gh is not logged in" >&2; exit 1; }
  # A version with no notes is not one to ship; this exits 1 and says so.
  tools/changelog-notes.py "$VERSION" >/dev/null
  if [ "$DRYRUN" = no ] && git rev-parse "$TAG" >/dev/null 2>&1; then
    echo "!! $TAG is already tagged — bump MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml" >&2; exit 1
  fi
  if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then
    echo "!! a release $TAG already exists on GitHub (a leftover draft, perhaps):" >&2
    echo "   gh release delete $TAG -R $REPO --yes" >&2; exit 1
  fi
fi

# "Which commit was that build from" needs an answer.
if [ "$NOTARIZE" = yes ] && [ -n "$(git status --porcelain)" ]; then
  echo "!! working tree is dirty — commit or stash before releasing" >&2
  git status --short >&2
  exit 1
fi

echo "==> building"
xcodegen generate >/dev/null
# --timestamp: notarization requires a secure timestamp on every signature, which a plain
# `xcodebuild build` leaves out.
xcodebuild -scheme Layland -configuration Release -destination "generic/platform=macOS" -derivedDataPath "$DERIVED" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" build | grep -E "error|warning: .*Layland|BUILD" || true
[ -d "$BUILT_APP" ] || { echo "!! build failed" >&2; exit 1; }
rm -rf "$OUT"; mkdir -p "$OUT"
ditto "$BUILT_APP" "$APP"

# Two traps, both of which make a correctly signed app look unsigned: -dvv, not -dv (the
# Authority lines only appear at the second v), and captured, not piped (grep -q exits at
# the first match and pipefail fails on codesign's SIGPIPE).
SIG_INFO=$(codesign -dvv "$APP" 2>&1 || true)
if ! grep -q "Authority=Developer ID Application" <<<"$SIG_INFO"; then
  echo "!! $APP is not signed with a Developer ID — cannot notarize" >&2
  echo "   check: security find-identity -v -p codesigning" >&2
  exit 1
fi
grep -q "^Timestamp=" <<<"$SIG_INFO" || { echo "!! $APP has no secure timestamp — notarization would refuse it" >&2; exit 1; }
codesign --verify --strict --deep "$APP"
[ "$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")" = "$BUILD" ] \
  || { echo "!! the app's CFBundleVersion is not $BUILD" >&2; exit 1; }

echo "==> packaging $DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
# The drag-to-install target.
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Layland" -srcfolder "$STAGE" -ov -format UDZO -imagekey zlib-level=9 "$DMG" >/dev/null
rm -rf "$STAGE"
echo "    $(du -h "$DMG" | cut -f1)"
# Signed too, so Gatekeeper has something to check before anything is mounted.
codesign --force --sign "Developer ID Application" --timestamp "$DMG"

if [ "$NOTARIZE" = no ] && [ "$DRYRUN" = no ]; then
  echo
  echo "built $DMG — NOT notarized, do not ship this one"
  exit 0
fi

if [ "$DRYRUN" = no ]; then
  echo "==> notarizing (a few minutes)"
  xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait
  echo "==> stapling"
  xcrun stapler staple "$DMG"
  echo "==> verifying"
  xcrun stapler validate "$DMG"
  spctl -a -t open --context context:primary-signature -v "$DMG"
fi

# The update archive. The app is stapled first (the DMG's ticket covers it, so no second
# round trip), so the copy Sparkle installs carries its own proof.
echo "==> update archive"
[ "$DRYRUN" = no ] && xcrun stapler staple "$APP"
ditto -c -k --keepParent "$APP" "$ZIP"
echo "    $(du -h "$ZIP" | cut -f1)"

# The appcast. generate_appcast signs the new archive with the Keychain key, adds an entry,
# and keeps the entries already in the file — which is why the previous release's copy is
# brought down first. The release notes are the CHANGELOG entry.
echo "==> appcast"
[ -x "$GENERATE_APPCAST" ] || { echo "!! $GENERATE_APPCAST missing — resolve packages (xcodebuild)" >&2; exit 1; }
rm -rf "$FEED_DIR"; mkdir -p "$FEED_DIR"
cp "$ZIP" "$FEED_DIR/"
tools/changelog-notes.py "$VERSION" --html > "$FEED_DIR/Layland-$VERSION.html"
if gh release download -R "$REPO" -p appcast.xml -D "$FEED_DIR" 2>/dev/null; then
  echo "    previous appcast: $(grep -c '<item>' "$FEED_DIR/appcast.xml") entries"
else
  echo "    no previous release — starting a fresh appcast"
fi
APPCAST_FLAGS=()
[ "$CRITICAL" = yes ] && APPCAST_FLAGS+=(--critical-update-version "")
# The odd expansion is for macOS's bash 3.2, where an empty array is unset under `set -u`.
"$GENERATE_APPCAST" \
  --download-url-prefix "$RELEASES/download/$TAG/" \
  --link "https://github.com/$REPO" \
  --embed-release-notes \
  ${APPCAST_FLAGS[@]+"${APPCAST_FLAGS[@]}"} \
  "$FEED_DIR"
grep -q "sparkle:version>$BUILD<" "$FEED_DIR/appcast.xml" \
  || { echo "!! appcast has no entry for build $BUILD" >&2; exit 1; }

# The GitHub release: a draft with every asset, published only once they are all up. The
# tag is made here because the appcast points at a URL with the tag's name in it.
NOTES="$OUT/notes-$VERSION.md"
tools/changelog-notes.py "$VERSION" > "$NOTES"
cp "$DMG" "$STABLE_DMG"
if [ "$DRYRUN" = no ]; then
  echo "==> tagging $TAG"
  git tag -a "$TAG" -m "$TAG"
  git push origin "$TAG"
fi
echo "==> github release $TAG (draft)"
gh release create "$TAG" -R "$REPO" --draft --target "$(git rev-parse HEAD)" \
  --title "Layland $VERSION" --notes-file "$NOTES" \
  "$STABLE_DMG" "$ZIP" "$FEED_DIR/appcast.xml"
ASSETS=$(gh release view "$TAG" -R "$REPO" --json assets -q '.assets[].name')
for want in "$(basename "$STABLE_DMG")" "$(basename "$ZIP")" appcast.xml; do
  grep -qx "$want" <<<"$ASSETS" || { echo "!! asset missing from the draft: $want" >&2; exit 1; }
done
echo "    assets: $(tr '\n' ' ' <<<"$ASSETS")"

if [ "$DRYRUN" = yes ]; then
  gh release delete "$TAG" -R "$REPO" --yes
  echo
  echo "dry run complete: the draft was created with all three assets and deleted again."
  echo "  $DMG is NOT notarized — do not ship this one"
  exit 0
fi

echo "==> publishing"
gh release edit "$TAG" -R "$REPO" --draft=false --latest

# What every installed copy will see; GitHub takes a moment to point "latest" at it.
echo "==> checking the feed"
for attempt in $(seq 1 12); do
  if curl -fsSL "$FEED_URL" | grep -q "sparkle:version>$BUILD<"; then
    echo "    $FEED_URL offers build $BUILD"
    break
  fi
  [ "$attempt" = 12 ] && {
    echo "!! $FEED_URL does not offer build $BUILD yet — GitHub may be slow to update 'latest'." >&2
    exit 1
  }
  sleep 5
done

echo
echo "ready: $DMG"
echo "  commit:   $(git rev-parse --short HEAD)"
echo "  release:  $RELEASES/tag/$TAG"
echo "  download: $RELEASES/latest/download/Layland.dmg"
echo "  feed:     $FEED_URL — every copy that checks is offered $VERSION"
