# Ghostty Fork Release Pipeline

## Goal

A GitHub Actions workflow that builds Ghostty for macOS arm64 and publishes a DMG as a GitHub Release when a version tag is pushed.

## Trigger

Tags matching `v*` (e.g., `v1.3.2-dz.1`). No builds on push to main or PRs.

## Build Environment

- Runner: `macos-latest` (Apple Silicon / arm64)
- Zig: 0.15.2 (project requirement from `build.zig.zon`)
- Xcode: whatever `macos-latest` provides (needed for `xcodebuild` which the Zig build invokes)

## Build Steps

1. Check out the repository
2. Install Zig 0.15.2 via `mlugg/setup-zig` action
3. Build the macOS app: `zig build -Doptimize=ReleaseFast -Demit-macos-app`
4. Install `create-dmg` via Homebrew
5. Package the `.app` bundle into a DMG using `create-dmg`
6. Create a GitHub Release for the tag with the DMG attached

## Build Command Details

The Zig build with `-Demit-macos-app` invokes `xcodebuild` under the hood (via `src/build/GhosttyXcodebuild.zig`) to compile the native Swift/macOS UI layer and produce a `Ghostty.app` bundle. The app bundle location after build: `zig-out/Ghostty.app`.

## DMG Creation

Use `create-dmg` (installed via `brew install create-dmg`) to wrap the `.app` into a DMG:

```
create-dmg \
  --volname "Ghostty" \
  --window-size 660 400 \
  --app-drop-link 400 190 \
  --icon "Ghostty.app" 180 190 \
  Ghostty.dmg \
  zig-out/Ghostty.app
```

## GitHub Release

Use `softprops/action-gh-release` to create the release from the tag and attach the DMG. The release title will be the tag name. The release body will note that the binary is unsigned and users should run `xattr -cr` after extracting.

## Explicitly Out of Scope

- Apple codesigning and notarization
- Sparkle auto-update feed
- Universal binaries (x86_64 support)
- Linux, Windows, or WASM builds
- Source tarballs or minisign signatures
- Publishing to any package manager (Homebrew, Snap, Flatpak, Nix)
- Cloud storage (R2, S3)
- Sentry/crash reporting integration

## Upstream Sync Workflow

This is a manual process, not automated:

1. Add upstream as a remote: `git remote add upstream https://github.com/ghostty-org/ghostty.git`
2. Fetch and merge: `git fetch upstream && git merge upstream/main`
3. Resolve any conflicts with your modifications
4. Tag and push when ready: `git tag v<version> && git push origin main --tags`

## File Changes

- **New:** `.github/workflows/release.yml` (single workflow file, ~50-60 lines)
- No other files created or modified

## License Compliance

Ghostty is MIT licensed. Distributing modified builds is explicitly permitted. The existing LICENSE file in the repo satisfies the attribution requirement.
