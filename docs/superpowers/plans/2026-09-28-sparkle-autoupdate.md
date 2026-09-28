# Sparkle Auto-Update from GitHub — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Imperum Tool in `/Applications` finds, verifies, installs and relaunches into new versions published as GitHub Releases, and offers "Check for Updates…" from every menu the app has.

**Architecture:** Sparkle 2 (SwiftPM binary package) is linked into the `ImperumTool` executable and its framework is copied into `Contents/Frameworks` by `build.sh`, which also signs it innermost-first. Three `Info.plist` keys point Sparkle at the public repo's `releases/latest/download/appcast.xml`. A new `release.sh` bumps the version, builds, notarises, signs the appcast with the EdDSA key from the Keychain, and publishes a GitHub Release carrying the DMG and the appcast.

**Tech Stack:** Swift 5.9 / SwiftPM, Sparkle 2.10, AppKit, bash, GitHub CLI (`gh`, logged in as `senadaruc`), Apple notarytool.

**Spec:** `docs/superpowers/specs/2026-09-28-sparkle-autoupdate-design.md`

## Global Constraints

- Every `swift`/`xcrun` invocation needs the Xcode toolchain: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`. The Command Line Tools cannot compile the app's SwiftUI macros.
- Repo: public, `senadaruc/imperum-tool`. Feed URL exactly `https://github.com/senadaruc/imperum-tool/releases/latest/download/appcast.xml`.
- Sparkle dependency `from: "2.6.0"` (resolves to 2.10.0 today). Only the `ImperumTool` target links it. `copystack` and the libraries stay Sparkle-free.
- Sparkle compares `CFBundleVersion` (integer build number). Every release bumps it by exactly 1 and sets `CFBundleShortVersionString` to the release argument.
- The private EdDSA key lives in the user's login Keychain only. It never enters the repo; the plist holds the public key.
- Automatic checks on (`SUEnableAutomaticChecks` = true), automatic install off (Sparkle default). Cadence stays Sparkle's default 24 h.
- No sandbox; entitlements file is unchanged.
- Commit messages end with the Co-Authored-By and Claude-Session trailers used on this branch.
- Work on a new branch `feat/sparkle-autoupdate` off `feat/caret-anchored-panel`.

## Review Focus

1. **`release.sh` rerun after a failed notarisation.** The version commit and tag already exist; a second run must not bump again. Task 6 tests it by running the script twice against a throwaway tag.
2. **`SUPublicEDKey` left at the placeholder.** Sparkle would silently reject every update. Task 5 makes `build.sh` fail on the placeholder and tests that failure.
3. **Running the debug binary outside a bundle** (`swift run`, `.build/debug/ImperumTool`). Sparkle throws when started from a non-bundle; the app must not crash or alert. Task 4 guards the start on the bundle extension and runs the debug binary to confirm.
4. **Malformed version argument** (`release.sh 0.3`, `release.sh v0.3.1`). Task 6 refuses anything that is not `X.Y.Z` and tests it.
5. **Pre-release must not reach users.** Task 7 publishes a pre-release first and confirms the running app sees no update, then promotes it and confirms it does.

---

### Task 1: Branch and public GitHub repo

**Files:**
- none in the tree; creates the remote

**Interfaces:**
- Produces: remote `origin` → `https://github.com/senadaruc/imperum-tool.git`; branch `feat/sparkle-autoupdate` pushed.

- [ ] **Step 1: Branch**

```bash
cd /Users/deepdark/WSMonitor
git switch -c feat/sparkle-autoupdate
```

- [ ] **Step 2: Secret scan before anything goes public**

```bash
git grep -n -i -E 'BEGIN (RSA|EC|OPENSSH|PRIVATE)|AuthKey_|\.p8|password *= *"[^"]+"|gho_|ghp_|sk-[A-Za-z0-9]{20}' -- . ':!docs/superpowers/plans' | grep -v -E 'cmuxSocketPassword|KEY="\$HOME' || echo "no secrets"
```

Expected: `no secrets`. The notarize scripts reference a key **path** under `$HOME/.secrets`, the key ID and the ASC issuer UUID; none of those is secret. If anything else prints, stop and remove it before Step 3.

- [ ] **Step 3: Create the repo and push**

```bash
gh repo create senadaruc/imperum-tool --public --description "Imperum Tool: WindowServer monitor, tap gestures and the Copy Stack clipboard for macOS" --source=. --remote=origin
git push -u origin feat/sparkle-autoupdate
git push origin main
```

Expected: `gh repo view senadaruc/imperum-tool --json visibility --jq .visibility` prints `PUBLIC`, and `git remote -v` shows origin.

---

### Task 2: Link Sparkle in Package.swift

**Files:**
- Modify: `Package.swift`

**Interfaces:**
- Produces: `import Sparkle` compiles in the `ImperumTool` target; `.build/release/Sparkle.framework` exists after a release build; the tools at `.build/artifacts/sparkle/Sparkle/bin/{generate_keys,generate_appcast}`.

- [ ] **Step 1: Edit Package.swift**

Replace the whole file with:

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ImperumTool",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .target(name: "ImperumCore"),
        .target(name: "CopyStackKit", dependencies: ["ImperumCore"]),
        .executableTarget(
            name: "ImperumTool",
            dependencies: [
                "ImperumCore", "CopyStackKit",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            linkerSettings: [
                // build.sh copies Sparkle.framework into Contents/Frameworks;
                // SwiftPM alone leaves the binary with no rpath that reaches it.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .executableTarget(
            name: "copystack",
            dependencies: ["CopyStackKit"]
        ),
        .testTarget(name: "ImperumCoreTests", dependencies: ["ImperumCore"]),
        .testTarget(name: "CopyStackKitTests", dependencies: ["CopyStackKit"]),
    ]
)
```

- [ ] **Step 2: Resolve and build**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build -c release 2>&1 | tail -3
ls .build/release/Sparkle.framework/Versions/B/
otool -l .build/release/ImperumTool | grep -A2 LC_RPATH | grep Frameworks
ls .build/artifacts/sparkle/Sparkle/bin/
```

Expected: `Build complete!`; the framework dir lists `Autoupdate Updater.app XPCServices Sparkle …`; the rpath line prints `path @executable_path/../Frameworks`; the bin listing includes `generate_appcast` and `generate_keys`.

- [ ] **Step 3: Run the tests so the dependency provably breaks nothing**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test 2>&1 | grep -E 'Executed .* tests' | tail -1
```

Expected: `Executed 265 tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Package.swift Package.resolved
git commit -m "build: link Sparkle 2 into ImperumTool with a Frameworks rpath"
```

---

### Task 3: EdDSA key and Info.plist keys

**Files:**
- Modify: `Resources/Info.plist`

**Interfaces:**
- Produces: plist keys `SUFeedURL`, `SUPublicEDKey`, `SUEnableAutomaticChecks`. Task 5's build guard greps for the literal `REPLACE_WITH_PUBLIC_ED_KEY`.

- [ ] **Step 1: Generate (or print) the signing key**

```bash
.build/artifacts/sparkle/Sparkle/bin/generate_keys
```

Expected: either a new key is created and its public part printed, or the existing key's public part is printed. A Keychain prompt may appear; allow it. Copy the base64 line after `SUPublicEDKey`.

If the run is unattended and the Keychain prompt cannot be answered, stop this task, leave the placeholder in place, and report that the user must run the command once.

- [ ] **Step 2: Add the three keys**

Insert before the closing `</dict>` of `Resources/Info.plist`, with the real key pasted in:

```xml
	<key>SUFeedURL</key>
	<string>https://github.com/senadaruc/imperum-tool/releases/latest/download/appcast.xml</string>
	<key>SUPublicEDKey</key>
	<string>REPLACE_WITH_PUBLIC_ED_KEY</string>
	<key>SUEnableAutomaticChecks</key>
	<true/>
```

- [ ] **Step 3: Validate**

```bash
plutil -lint Resources/Info.plist
/usr/libexec/PlistBuddy -c 'Print :SUFeedURL' -c 'Print :SUPublicEDKey' -c 'Print :SUEnableAutomaticChecks' Resources/Info.plist
```

Expected: `OK`, the URL, a 44-character base64 key, `true`.

- [ ] **Step 4: Commit**

```bash
git add Resources/Info.plist
git commit -m "feat(update): Sparkle feed URL, public key and automatic checks in Info.plist"
```

---

### Task 4: Updater controller and "Check for Updates…" entry points

**Files:**
- Modify: `Sources/ImperumTool/AppController.swift` (properties near line 6–17; `buildMainMenu()` around line 77–91)
- Modify: `Sources/ImperumTool/ClipboardStatusItem.swift` (menu build around line 52–65)
- Modify: `Sources/ImperumTool/Settings.swift` (About section around line 185–200)

**Interfaces:**
- Produces: `@objc func checkForUpdates(_ sender: Any?)` on `AppController`, reachable through the responder chain exactly like the existing `AppController.showSettings`.

- [ ] **Step 1: Updater in AppController**

At the top of `AppController.swift` add `import Sparkle` after `import AppKit`. Next to the other stored properties add:

```swift
    /// Sparkle. Started only when running as a bundle: the debug binary
    /// under .build/ is not one, and Sparkle throws on start there.
    private lazy var updater = SPUStandardUpdaterController(
        startingUpdater: Bundle.main.bundleURL.pathExtension == "app",
        updaterDelegate: nil, userDriverDelegate: nil)
```

Add the action next to `showSettings`:

```swift
    @objc func checkForUpdates(_ sender: Any?) { updater.checkForUpdates(sender) }
```

In `buildMainMenu()` replace the About line and the separator after it with:

```swift
        appMenu.addItem(withTitle: "About Imperum Tool", action: #selector(showAbout), keyEquivalent: "")
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkForUpdates(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
```

The loop at the end of `buildMainMenu()` already sets `target = self` on items with no target, so the new item routes to `checkForUpdates`.

In `applicationDidFinishLaunching` (or the init that builds the menu, whichever runs first) add one line so the scheduled check starts with the app even if no menu is ever opened:

```swift
        _ = updater
```

- [ ] **Step 2: Status-item menu**

In `ClipboardStatusItem.swift`, right before the `Settings…` item is added (the `let s = NSMenuItem(title: "Settings…"` line), insert:

```swift
        m.addItem(NSMenuItem(title: "Check for Updates…", action: #selector(AppController.checkForUpdates(_:)), keyEquivalent: ""))
```

No target: nil-targeted items travel the responder chain to the app delegate, the same route `NSApp.sendAction(#selector(AppController.showSettings)…)` already uses in this file's `onSettings` wiring.

- [ ] **Step 3: Settings › About button**

In `Settings.swift`, inside the `HStack(spacing: 10)` of the About section, after the inner `VStack` that shows the name and version, add:

```swift
                        Spacer()
                        Button("Check for Updates…") {
                            NSApp.sendAction(#selector(AppController.checkForUpdates(_:)), to: nil, from: nil)
                        }
```

- [ ] **Step 4: Build and run the non-bundled debug binary (Review Focus 3)**

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build 2>&1 | grep -E 'error|Build complete'
(.build/debug/ImperumTool & sleep 4; pkill -x ImperumTool) 2>&1 | grep -i -E 'sparkle|exception|crash' || echo "debug binary ran without Sparkle errors"
```

Expected: `Build complete!` and `debug binary ran without Sparkle errors`. (Sparkle's framework is found via the build dir at debug time because SwiftPM places it beside the binary and `@executable_path/../Frameworks` is absent; if the binary fails to load with `Library not loaded: @rpath/Sparkle.framework`, add a second rpath `@executable_path` to the `unsafeFlags` list in Task 2 and rebuild.)

- [ ] **Step 5: Commit**

```bash
git add Sources/ImperumTool/AppController.swift Sources/ImperumTool/ClipboardStatusItem.swift Sources/ImperumTool/Settings.swift
git commit -m "feat(update): Sparkle updater with Check for Updates in the app menu, status item and About"
```

---

### Task 5: build.sh bundles and signs the framework

**Files:**
- Modify: `build.sh`

**Interfaces:**
- Consumes: `.build/release/Sparkle.framework` (Task 2), `SUPublicEDKey` placeholder literal (Task 3).
- Produces: `build/Imperum Tool.app/Contents/Frameworks/Sparkle.framework`, signed; the script fails on the placeholder key.

- [ ] **Step 1: Replace build.sh**

```bash
#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
# The bare Command Line Tools cannot compile the SwiftUI macros this app uses.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
ID="Developer ID Application: Imperum B.V. (9TZGSR8224)"
APP="build/Imperum Tool.app"
FW="$APP/Contents/Frameworks/Sparkle.framework"

if grep -q REPLACE_WITH_PUBLIC_ED_KEY Resources/Info.plist; then
  echo "Resources/Info.plist still has the SUPublicEDKey placeholder; run generate_keys and paste the public key" >&2
  exit 1
fi

swift build -c release
/bin/rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp .build/release/ImperumTool "$APP/Contents/MacOS/ImperumTool"
cp .build/release/copystack "$APP/Contents/MacOS/copystack"
ditto .build/release/Sparkle.framework "$FW"

# Sparkle: sign the nested pieces first, then the framework, then ours.
SIGN=(codesign --force --options runtime --timestamp --sign "$ID")
"${SIGN[@]}" "$FW/Versions/B/XPCServices/Installer.xpc"
"${SIGN[@]}" --preserve-metadata=entitlements "$FW/Versions/B/XPCServices/Downloader.xpc"
"${SIGN[@]}" "$FW/Versions/B/Autoupdate"
"${SIGN[@]}" "$FW/Versions/B/Updater.app"
"${SIGN[@]}" "$FW"

"${SIGN[@]}" --identifier io.imperum.tool.copystack "$APP/Contents/MacOS/copystack"
"${SIGN[@]}" --entitlements Resources/ImperumTool.entitlements "$APP/Contents/MacOS/ImperumTool"
"${SIGN[@]}" --entitlements Resources/ImperumTool.entitlements "$APP"
codesign --verify --strict --verbose=2 "$APP"
codesign --verify --deep --strict "$APP"
codesign -d --entitlements :- "$APP" | grep -q apple-events || { echo "entitlements missing"; exit 1; }
echo "Built + signed: $APP"
```

- [ ] **Step 2: Test the placeholder guard (Review Focus 2)**

```bash
cp Resources/Info.plist /tmp/Info.plist.bak
sed -i '' 's|<string>[A-Za-z0-9+/=]\{40,\}</string>|<string>REPLACE_WITH_PUBLIC_ED_KEY</string>|' Resources/Info.plist
./build.sh; echo "exit=$?"
cp /tmp/Info.plist.bak Resources/Info.plist
git diff --stat Resources/Info.plist
```

Expected: the placeholder message and `exit=1`; the final diff is empty.

- [ ] **Step 3: Real build and verification**

```bash
./build.sh 2>&1 | grep -E 'error|Built \+ signed|valid on disk'
codesign -dv "build/Imperum Tool.app/Contents/Frameworks/Sparkle.framework" 2>&1 | grep Authority | head -1
otool -L "build/Imperum Tool.app/Contents/MacOS/ImperumTool" | grep Sparkle
open "build/Imperum Tool.app"; sleep 4; pgrep -x ImperumTool && echo running; pkill -x ImperumTool
```

Expected: `Built + signed`, `Authority=Developer ID Application: Imperum B.V. (9TZGSR8224)`, the `@rpath/Sparkle.framework/…` line, and `running`.

- [ ] **Step 4: Commit**

```bash
git add build.sh
git commit -m "build: bundle and sign Sparkle.framework; default to the Xcode toolchain; guard the placeholder key"
```

---

### Task 6: release.sh and README

**Files:**
- Create: `release.sh`
- Modify: `README.md` (the `## Build` section, line 168–174)

**Interfaces:**
- Consumes: `build.sh`, `notarize.sh`, `make-dmg.sh`, `.build/artifacts/sparkle/Sparkle/bin/generate_appcast`, `gh`.
- Produces: a tagged commit `chore(release): X.Y.Z (build N)` and a GitHub Release `vX.Y.Z` with `ImperumTool-X.Y.Z.dmg` and `appcast.xml`.

- [ ] **Step 1: Write release.sh**

```bash
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
cp "$DMG" "$STAGE/"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  -o "$STAGE/appcast.xml" "$STAGE"

git push origin "$BRANCH" --follow-tags
gh release create "$TAG" "$DMG" "$STAGE/appcast.xml" --repo "$REPO" --title "$VERSION" --generate-notes $PRE
echo "Released $TAG: https://github.com/$REPO/releases/tag/$TAG"
```

Then `chmod +x release.sh`.

- [ ] **Step 2: Test the refusals without publishing anything (Review Focus 1 and 4)**

```bash
./release.sh 0.3; echo "exit=$?"
./release.sh v0.3.1; echo "exit=$?"
touch scratch.txt; ./release.sh 9.9.9; echo "exit=$?"; rm scratch.txt
git tag -a v9.9.9 -m test; ./release.sh 9.9.9 2>&1 | head -2; echo "exit=$?"; git tag -d v9.9.9
```

Expected, in order: usage message and `exit=2` twice; the dirty-tree message and `exit=1`; then `tag v9.9.9 exists; skipping the version bump` followed by the "different version" message and `exit=1`. Nothing was built or pushed.

- [ ] **Step 3: README**

Replace the `## Build` block (the four-line code block and nothing else) with:

```markdown
## Build

    ./build.sh                 # SwiftPM release → "build/Imperum Tool.app", Developer ID signed
    ./notarize.sh              # optional: notarize + staple (only to share the .app)
    cp -R "build/Imperum Tool.app" /Applications/
    open "/Applications/Imperum Tool.app"

`build.sh` uses the Xcode toolchain (`DEVELOPER_DIR`), since the bare
Command Line Tools cannot compile the SwiftUI macros.

### Release and auto-update

The app updates itself with [Sparkle](https://sparkle-project.org) from
this repo's GitHub Releases: it checks daily and from "Check for Updates…"
in the app menu, the clipboard menu-bar menu and Settings › About, then
offers "Install and Relaunch". Pre-releases are never offered.

    ./release.sh 0.3.1         # bump, tag, build, notarize, DMG, signed appcast, GitHub Release
    ./release.sh 0.3.2 --pre   # same, marked pre-release (kept off the update feed)

One-time setup on the release machine: run
`.build/artifacts/sparkle/Sparkle/bin/generate_keys` once. It stores the
private EdDSA key in your login Keychain and prints the public key that
lives in `Resources/Info.plist` under `SUPublicEDKey`. Updates signed with
any other key are rejected by every installed copy.
```

- [ ] **Step 4: Commit**

```bash
git add release.sh README.md
git commit -m "build: release.sh publishes a Sparkle-signed GitHub Release; document auto-update"
```

---

### Task 7: End-to-end: first release, install, pre-release check, real update

**Files:**
- none new; `Resources/Info.plist` is bumped by the script twice.

**Interfaces:**
- Consumes: everything above.

- [ ] **Step 1: Merge the branch to main so releases come from main**

```bash
git switch main
git merge --no-ff feat/caret-anchored-panel -m "Merge feat/caret-anchored-panel"
git merge --no-ff feat/sparkle-autoupdate -m "Merge feat/sparkle-autoupdate"
git push origin main
```

- [ ] **Step 2: Release 0.3.1 and install it**

```bash
./release.sh 0.3.1
osascript -e 'tell application "Imperum Tool" to quit'; sleep 2
/bin/rm -rf "/Applications/Imperum Tool.app" && cp -R "build/Imperum Tool.app" /Applications/ && open "/Applications/Imperum Tool.app"
```

Expected: `Released v0.3.1: …`; the release page lists `ImperumTool-0.3.1.dmg` and `appcast.xml`; `curl -sL https://github.com/senadaruc/imperum-tool/releases/latest/download/appcast.xml | grep sparkle:version` prints `sparkle:version="4"`.

- [ ] **Step 3: Pre-release 0.3.2 and confirm it is invisible (Review Focus 5)**

```bash
./release.sh 0.3.2 --pre
curl -sL https://github.com/senadaruc/imperum-tool/releases/latest/download/appcast.xml | grep -o 'sparkle:version="[0-9]*"'
```

Expected: still `sparkle:version="4"`. In the running app choose "Check for Updates…" from the menu-bar clipboard menu: Sparkle reports "You're up to date!".

- [ ] **Step 4: Promote and confirm the update installs**

```bash
gh release edit v0.3.2 --repo senadaruc/imperum-tool --prerelease=false --latest
curl -sL https://github.com/senadaruc/imperum-tool/releases/latest/download/appcast.xml | grep -o 'sparkle:version="[0-9]*"'
```

Expected: `sparkle:version="5"`. In the app choose "Check for Updates…" from the app menu: Sparkle offers 0.3.2, "Install and Relaunch" replaces the app and relaunches it. Verify:

```bash
sleep 20; /usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "/Applications/Imperum Tool.app/Contents/Info.plist"; pgrep -x ImperumTool && echo running
```

Expected: `0.3.2` and `running`.

- [ ] **Step 5: Record the outcome**

Tick the steps in this plan and commit it:

```bash
git add docs/superpowers/plans/2026-09-28-sparkle-autoupdate.md
git commit -m "docs: tick the executed Sparkle auto-update plan"
git push origin main
```
