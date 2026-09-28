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
VERSION="${1:-}"
PRE=""
[ "${2:-}" = "--pre" ] && PRE="--prerelease"

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "usage: $0 X.Y.Z [--pre]" >&2; exit 2; }
[ -z "$(git status --porcelain)" ] || { echo "working tree is dirty; commit or stash first" >&2; exit 1; }
BRANCH=$(git symbolic-ref --short -q HEAD) || { echo "detached HEAD; check out a branch" >&2; exit 1; }
TAG="v$VERSION"

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  echo "tag $TAG exists; skipping the version bump"
  [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$PLIST")" = "$VERSION" ] \
    || { echo "tag $TAG exists but $PLIST says a different version" >&2; exit 1; }
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
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  -o "$STAGE/appcast.xml" "$STAGE"

git push origin "$BRANCH" --follow-tags
gh release create "$TAG" "$DMG" "$STAGE/appcast.xml" --repo "$REPO" --title "$VERSION" --generate-notes $PRE
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
