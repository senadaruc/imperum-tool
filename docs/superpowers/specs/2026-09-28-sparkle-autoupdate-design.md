# Auto-update from GitHub (Sparkle) — Design

Date: 2026-09-28. Branch: a new `feat/sparkle-autoupdate` off
`feat/caret-anchored-panel`.

## Goal

Imperum Tool installed in `/Applications` updates itself. A new version is
published as a GitHub Release; every running copy finds it within a day,
downloads it, verifies it, swaps itself in place and relaunches. The user
can also check by hand from the app menu and the menu-bar clipboard menu.

## Decisions already made

- **Updater: Sparkle 2** (SwiftPM binary package). Signature check,
  in-place replace, relaunch and the "Check for Updates…" UI come with it.
  A hand-rolled GitHub-API updater would reimplement all four badly.
- **Host: GitHub Releases** on a new public repo `senadaruc/imperum-tool`.
  Sparkle fetches without credentials, so release assets must be public.
  The source repo is public too.
- **Feed URL:** `https://github.com/senadaruc/imperum-tool/releases/latest/download/appcast.xml`.
  GitHub resolves `releases/latest/download/<asset>` to the newest
  non-pre-release release, so the feed never needs a gh-pages branch and
  a pre-release never reaches users.
- **Update payload:** the existing notarised, stapled DMG from
  `make-dmg.sh`. Sparkle mounts DMGs directly.
- **Versioning:** Sparkle compares `CFBundleVersion` (the build number,
  already an integer that bumps every release) and shows
  `CFBundleShortVersionString`. Nothing changes in how versions are
  written; the release script bumps both.
- **No sandbox** (the app has none, and the entitlements stay as they
  are), so Sparkle's non-XPC install path is used. Its XPC services are
  still shipped and signed because they are inside the framework.

## Components

### Package.swift

- `dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")]`.
- `ImperumTool` target gains `.product(name: "Sparkle", package: "Sparkle")`
  and `linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]`
  so the binary finds the framework inside the bundle. `copystack` and the
  library targets are untouched.
- SwiftPM places `Sparkle.framework` and the CLI tools (`generate_keys`,
  `generate_appcast`) under `.build/artifacts/sparkle/Sparkle/`. No
  separate install.

### Resources/Info.plist

Three new keys:

| Key | Value |
|---|---|
| `SUFeedURL` | the feed URL above |
| `SUPublicEDKey` | the public key printed by `generate_keys` (user runs this once; the private key lives in their login Keychain and is never committed) |
| `SUEnableAutomaticChecks` | `true` — check and prompt without the first-launch permission dialog; the tool is internal, so opting users in by default is right |

Default cadence stays Sparkle's 24 h. Automatic *download and install*
stays off: Sparkle prompts "Install and Relaunch" when an update is
found, which is the safe default for a background app that owns the
user's clipboard history.

### AppController

- Holds one `SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)`,
  created at init so the scheduled check starts with the app.
- App menu: "Check for Updates…" between "About Imperum Tool" and the
  separator before "Settings…", target the updater controller, action
  `checkForUpdates(_:)`. Sparkle disables the item itself while a check
  runs.
- Clipboard status-item menu gets the same item above "Settings…", wired
  through a new `onCheckForUpdates` closure like the existing `onSettings`.
  `ClipboardStatusItem` does not import Sparkle.
- Settings › About section: one line "Version 0.3.1 (4)" already exists
  or is added, plus a "Check for Updates…" button calling the same
  action. Keeps the entry point discoverable from the window.

### build.sh

- First line after `set -euo pipefail`: `export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"`.
  The bare Command Line Tools toolchain cannot compile the SwiftUI macros,
  which is why the script failed today.
- After copying the executables: `mkdir Contents/Frameworks`, `ditto`
  `.build/release/Sparkle.framework` into it.
- Sign, innermost first, all with `--force --options runtime --timestamp`:
  1. `Sparkle.framework/Versions/B/XPCServices/Installer.xpc` and
     `Downloader.xpc` (with `--preserve-metadata=entitlements`, as Sparkle's
     docs require for the downloader's sandbox entitlement),
  2. `Sparkle.framework/Versions/B/Autoupdate` and `Updater.app`,
  3. `Sparkle.framework`,
  4. then `copystack`, `ImperumTool`, the bundle, exactly as now.
- The existing `codesign --verify --deep --strict` then covers the
  framework too.

### release.sh (new)

`./release.sh 0.3.1` does, stopping on the first failure:

1. Refuses to run with a dirty tree or off a branch.
2. Bumps `CFBundleShortVersionString` to the argument and `CFBundleVersion`
   to previous + 1 in `Resources/Info.plist`; commits
   `chore(release): 0.3.1 (build 4)` and tags `v0.3.1`.
3. `./build.sh`, `./notarize.sh`, `./make-dmg.sh`.
4. Copies the new DMG alone into `build/appcast/`, runs
   `generate_appcast --download-url-prefix https://github.com/senadaruc/imperum-tool/releases/download/v0.3.1/ build/appcast/`.
   Only the newest item matters to clients; delta updates are out of scope.
5. `git push` with tags, then
   `gh release create v0.3.1 build/ImperumTool-0.3.1.dmg build/appcast/appcast.xml --title 0.3.1 --notes-from-tag`
   (notes from the tag message; the script asks for them on stdin if the
   tag has none).

A `--pre` flag passes `--prerelease` to `gh`, which keeps that build off
the `latest` feed.

### Repo

- `git remote add origin https://github.com/senadaruc/imperum-tool.git`
  after `gh repo create senadaruc/imperum-tool --public`.
- `.gitignore` already excludes `build/` and `.build/`; add nothing.
- README "Build" section gains a "Release" subsection describing
  `release.sh`, the one-time `generate_keys` step, and that updates are
  checked daily and from the menus.

## Data flow

Launch → Sparkle reads the three plist keys → after 24 h (or on
"Check for Updates…") GETs the feed URL → GitHub 302s to the asset →
Sparkle compares the newest item's `sparkle:version` to `CFBundleVersion`
→ if newer, shows release notes and "Install and Relaunch" → downloads
the DMG, verifies the EdDSA signature against `SUPublicEDKey` and the
Developer ID signature of the app inside → replaces
`/Applications/Imperum Tool.app` → relaunches.

## Error handling

- Feed unreachable, malformed, or signature mismatch: Sparkle reports it
  in its own alert on a manual check and stays silent on a scheduled one.
  No app code involved.
- Release script: each step is a separate command under `set -e`; a
  notarisation failure leaves the version commit and tag in place but
  unpushed, so the fix is to rerun after fixing the cause. The script
  detects an existing tag for the version and skips the bump.
- A missing `SUPublicEDKey` (placeholder not replaced) makes Sparkle
  refuse every update; the build script greps for the placeholder and
  fails.

## Testing

- Unit: none. Sparkle and the plist are configuration; there is no logic
  to test in-repo.
- Build: `build.sh` verify step passes with `--deep --strict`;
  `otool -L` shows `@rpath/Sparkle.framework`; `spctl -a -t exec` accepts
  the notarised app.
- End to end, on this Mac: install the 0.3.1 build to `/Applications`,
  publish 0.3.2 as a pre-release first to check the feed is *not* seen,
  then promote it and confirm "Check for Updates…" offers 0.3.2, installs,
  and relaunches with the new version in About.

## Out of scope

Delta updates, a Settings toggle for automatic checks (Sparkle's own
"Automatically check" prompt covers it), Homebrew cask, `copystack`
updating on its own (it ships inside the bundle).

## User's one-time actions

1. `gh repo create senadaruc/imperum-tool --public` (or let the plan do it
   with the CLI, which is already logged in as senadaruc).
2. Run `.build/artifacts/sparkle/Sparkle/bin/generate_keys` once and paste
   the printed public key into `Resources/Info.plist`.
