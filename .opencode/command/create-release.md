---
description: Create and push a release tag (e.g. /create-release 1.0.0 or /create-release desktop 0.1.0)
---

Create a release tag and push it to origin. The matching GitHub Action will automatically build for all platforms and create the GitHub Release.

## Tag schemes (monorepo)

| App | Argument | Tag | Workflow |
|---|---|---|---|
| Console launcher (`apps/marcer_console/`) | `/create-release 1.0.0` | `v1.0.0` | `release.yml` |
| Flutter desktop (`apps/marcer_desktop/`) | `/create-release desktop 0.1.0` | `desktop-v0.1.0` | `desktop-release.yml` |

## Steps

1. Parse the arguments ($ARGUMENTS):
   - Optional leading app selector `launcher` or `desktop` (default `launcher`).
     - `launcher` → tag prefix `v`
     - `desktop` → tag prefix `desktop-v`
   - Remaining token is the version; must be provided, otherwise show error and stop.
   - Must match semver format (e.g. 1.0.0, 0.9.1, 2.0.0-beta.1).
   - Compose `TAG="<prefix><version>"` (e.g. `v1.0.0` or `desktop-v0.1.0`).

2. Check for uncommitted changes:
   - Run `git status --porcelain`
   - If any output, warn the user and stop (commit first).

3. Find the previous tag of the same app:
   - `launcher`: `git describe --tags --match 'v*' --abbrev=0 HEAD`
   - `desktop`: `git describe --tags --match 'desktop-v*' --abbrev=0 HEAD`
   - If no previous tag exists (first release of that app), note this and skip to step 5.
   - Report the previous tag to the user (e.g. "Previous desktop tag found: desktop-v0.1.0").

4. Analyze changes since the previous tag:
   - Run `git log --oneline <PREV_TAG>..HEAD` to list all commits between the previous tag and HEAD
   - Read the changed files to understand context
   - Write a concise, well-structured release summary in English with:
     - A one-line overview
     - Bullet points for each notable change (features, fixes, breaking changes)
     - Keep it developer-friendly, no fluff

5. Create release commit with the summary as message:
   - Run `git commit --allow-empty -m "release $TAG\n\n<summary>"`
   - The commit message IS the release notes — the GitHub Action picks it up automatically

6. Create annotated tag on that commit:
   - Run `git tag -a $TAG -m "Release $TAG"`

7. Push commit and tag:
   - Run `git push origin main --tags` (or current branch)

8. Confirm success with the tag name (e.g. `v1.0.0` or `desktop-v0.1.0`).
