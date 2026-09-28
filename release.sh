#!/bin/bash
# Publish a release: bump the version, tag, build, notarize, make the DMG,
# sign the Sparkle appcast and create the GitHub Release the app updates from.
#   ./release.sh 0.3.1            # release
#   ./release.sh 0.3.1 --pre      # pre-release: never reaches the "latest" feed
set -euo pipefail
cd "$(dirname "$0")"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

REPO="senadaruc/imperum-tool"
PLIST="Resources/Info.plist"
KEYS=".build/artifacts/sparkle/Sparkle/bin"
VERSION="${1:-}"
PRE=""
usage() { echo "usage: $0 X.Y.Z [--pre]" >&2; exit 2; }
[ $# -le 2 ] || usage
case "${2:-}" in
  "") ;;
  --pre) PRE="--prerelease" ;;
  *) usage ;;   # anything else (e.g. --prerelease, -pre) would silently publish to everyone
esac

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || usage
[ -z "$(git status --porcelain)" ] || { echo "working tree is dirty; commit or stash first" >&2; exit 1; }
BRANCH=$(git symbolic-ref --short -q HEAD) || { echo "detached HEAD; check out a branch" >&2; exit 1; }
TAG="v$VERSION"

# Nothing with a secret, Apple signing material or personal data goes public.
./scan-release.sh . || { echo "release blocked by scan-release.sh" >&2; exit 1; }

# The public key in the plist must be the one this Keychain signs with, or
# generate_appcast writes an unsigned item that every installed copy rejects.
PLIST_KEY=$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$PLIST")
KEYCHAIN_KEY=$("$KEYS/generate_keys" -p 2>/dev/null | tr -d '[:space:]')
[ "$PLIST_KEY" = "$KEYCHAIN_KEY" ] \
  || { echo "SUPublicEDKey in $PLIST does not match the key in this Keychain (generate_keys -p)" >&2; exit 1; }

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG exists; skipping the version bump"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION" ] \
    || { echo "tag $TAG exists but $PLIST says a different version" >&2; exit 1; }
  # A rerun after a fix commit must ship the commit the tag names. Move an
  # unpublished tag to HEAD; never move one that is already on origin.
  if [ "$(git rev-parse "$TAG^{commit}")" != "$(git rev-parse HEAD)" ]; then
    if [ -z "$(git ls-remote --tags origin "refs/tags/$TAG")" ]; then
      git tag -f -a "$TAG" -m "Imperum Tool $VERSION" >/dev/null
      echo "moved unpublished tag $TAG to HEAD"
    else
      echo "tag $TAG is already on origin and does not point at HEAD; bump to a new version" >&2; exit 1
    fi
  fi
else
  BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST") + 1 ))
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" -c "Set :CFBundleVersion $BUILD" "$PLIST"
  git add "$PLIST"
  git commit -q -m "chore(release): $VERSION (build $BUILD)"
  git tag -a "$TAG" -m "Imperum Tool $VERSION (build $BUILD)"
  echo "bumped to $VERSION (build $BUILD), tagged $TAG"
fi

./build.sh
./notarize.sh
./make-dmg.sh

DMG="build/ImperumTool-$VERSION.dmg"
STAGE="build/appcast"
/bin/rm -rf "$STAGE"; mkdir -p "$STAGE"
/bin/cp "$DMG" "$STAGE/"
"$KEYS/generate_appcast" \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  -o "$STAGE/appcast.xml" "$STAGE"
grep -q 'sparkle:edSignature=' "$STAGE/appcast.xml" \
  || { echo "appcast is unsigned; refusing to publish an update no client would accept" >&2; exit 1; }

git push origin "$BRANCH" --follow-tags
gh release create "$TAG" "$DMG" "$STAGE/appcast.xml" --repo "$REPO" --title "$VERSION" --generate-notes $PRE
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
