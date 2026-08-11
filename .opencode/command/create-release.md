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

3. Find the previous tag dynamically:
   - Run `git describe --tags --abbrev=0 HEAD` to find the most recent tag before HEAD
   - If no previous tag exists (first release), note this and skip to step 5
   - Report the previous tag to the user (e.g. "Previous tag found: v0.9.5")

4. Analyze changes since the previous tag:
   - Run `git log --oneline <PREV_TAG>..HEAD` to list all commits between the previous tag and HEAD
   - Read the changed files to understand context
   - Write a concise, well-structured release summary in English with:
     - A one-line overview
     - Bullet points for each notable change (features, fixes, breaking changes)
     - Keep it developer-friendly, no fluff

5. Create release commit with the summary as message:
   - Run `git commit --allow-empty -m "release v$ARGUMENTS\n\n<summary>"`
   - The commit message IS the release notes — the GitHub Action picks it up automatically

6. Create annotated tag on that commit:
   - Run `git tag -a v$ARGUMENTS -m "Release v$ARGUMENTS"`

7. Push commit and tag:
   - Run `git push origin main --tags` (or current branch)

8. Confirm success with the version number
