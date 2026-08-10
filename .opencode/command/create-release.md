---
description: Create and push a release tag (e.g. /create-release 1.0.0)
---

Create a release tag and push it to origin. The GitHub Action will automatically build for all platforms and create the GitHub Release.

## Steps

1. Validate the version argument ($ARGUMENTS):
   - Must be provided, otherwise show error and stop
   - Must match semver format (e.g. 1.0.0, 0.9.1, 2.0.0-beta.1)

2. Check for uncommitted changes:
   - Run `git status --porcelain`
   - If any output, warn the user and stop (commit first)

3. Analyze changes since last release:
   - Run `git log --oneline $(git describe --tags --abbrev=0 HEAD)..HEAD` to list all commits
   - Read the changed files to understand context
   - Write a concise, well-structured release summary in English with:
     - A one-line overview
     - Bullet points for each notable change (features, fixes, breaking changes)
     - Keep it developer-friendly, no fluff

4. Create release commit with the summary as message:
   - Run `git commit --allow-empty -m "release v$ARGUMENTS\n\n<summary>"`
   - The commit message IS the release notes — the GitHub Action picks it up automatically

5. Create annotated tag on that commit:
   - Run `git tag -a v$ARGUMENTS -m "Release v$ARGUMENTS"`

6. Push commit and tag:
   - Run `git push origin main --tags` (or current branch)

7. Confirm success with the version number
