## Release Ghoztty

Follow these steps exactly to release a new version of Ghoztty (custom Ghostty fork).

### Step 1: Analyze Changes

Run `git log $(git describe --tags --abbrev=0 2>/dev/null || echo HEAD~20)..HEAD --oneline` to see all commits since the last release.

Categorize changes into: new features, improvements, bug fixes, upstream syncs.

Recommend a version tag (e.g. `v1.3.2-dz.2`) with clear reasoning:
- The base version (1.3.2) should match the upstream Ghostty version the fork is based on
- The `-dz.N` suffix increments with each fork release
- Bump the base version when syncing with a new upstream release

Present the recommendation and ask the user to confirm or override. Do NOT proceed until confirmed.

### Step 2: Generate Release Notes

From the categorized commits, write user-facing release notes. Rules:
- Write in a friendly tone focused on what the user can now do or how their experience improved
- Do NOT use raw commit messages — rewrite them as benefits
- Group related commits into single bullet points
- Separate fork-specific changes from upstream syncs
- Format:
  ```
  ## What's new in Ghoztty vX.Y.Z-dz.N

  ### Fork Changes
  - **Feature name** — What the user can now do, in plain language.
  - **Improvement** — How the experience got better.
  - **Fix** — What no longer happens / what works correctly now.

  ### Upstream Sync
  - Synced with Ghostty vX.Y.Z (if applicable)
  ```

Present the notes and ask the user to approve or edit. Do NOT proceed until approved.

### Step 3: Tag and Push

```bash
git tag vX.Y.Z-dz.N
git push fork main --tags
```

This triggers the release workflow which builds, signs, notarizes, and publishes a DMG to GitHub Releases.

### Step 4: Monitor Build

Watch the release workflow:
```bash
gh run list --repo dzearing/ghostty --workflow release.yml --limit 1
```

Monitor it until completion. If it fails, check logs with `gh run view <id> --repo dzearing/ghostty --log-failed` and fix the issue.

### Step 5: Publish Release

Once the DMG is built, update the GitHub release with the friendly notes:

```bash
gh release edit vX.Y.Z-dz.N --repo dzearing/ghostty --title "Ghoztty vX.Y.Z-dz.N" --notes "$(cat <<'NOTES'
## What's new in Ghoztty vX.Y.Z-dz.N

{the approved release notes from step 2}

---

### Installation
Download `Ghoztty.dmg`, open it, and drag to Applications.
Installs alongside official Ghostty — separate app with its own bundle ID.

### Requirements
- macOS 13+ (Apple Silicon)
NOTES
)"
```

### Step 6: Report

Show a summary:
- Version released
- Release notes
- Link to the GitHub release
- Link to the GitHub Actions run
