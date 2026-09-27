---
name: release
description: Prepare and publish a GitHub release for the zlap Zig library when the user requests a release.
---

# Release zlap

Use this skill for a requested GitHub release of zlap. zlap is a Zig library and releases have no binary artifacts.

## Prepare

1. Fetch `origin/main`, then require that `main` is checked out, the working tree is clean, and local `main` equals `origin/main`. Record this SHA as the base SHA. Stop and resolve or ask for direction if the release cannot be based on this clean, current `main`.
2. Use a user-specified valid target SemVer, or otherwise the root manifest version. For an explicit release request that needs manifest edits, create a release branch from this current `main` before updating the root manifest and aligned examples manifest. Never commit or push a version bump directly to `main`. For a preparation-only request, report required edits without applying them. Permit only intended manifest changes.
3. Run the release checks:

   ```sh
   zig build test
   zig build
   (cd examples && zig build fmt)
   (cd examples && zig build)
   ```

4. Set the tag name to `v<version>`. Confirm it is absent locally, absent from `origin`, and has no GitHub release. Never move, replace, or reuse an existing published tag.

## Publish

An explicit release request authorizes the needed commit, push, tag, and GitHub release. A request only to prepare or check a release is read-only and stops before publication.

1. If the manifests changed, commit only those changes on the release branch with the Conventional Commit `chore: release v<version>` and push the branch. Prepare this exact Conventional Commit PR title and body:

   ```text
   chore: release v<version>

   ## Summary

   Release zlap v<version>.

   ## Checks

   - zig build test
   - zig build
   - (cd examples && zig build fmt)
   - (cd examples && zig build)
   ```

   Get user approval of this title and body before opening the PR. After approval, open the PR. Wait for the required `Build and test` job in workflow `CI`. If a required check is invalidated by newer `main`, update the release branch, rerun the release checks, verify the PR is mergeable, and wait for `Build and test` on the updated branch. Squash merge the PR and record its resulting squash merge commit SHA as the intended SHA.
2. If the manifests were already current, skip the PR and use the recorded base SHA as the intended SHA. Fetch `origin/main`, switch to `main`, and fast-forward local `main` to `origin/main`. Confirm that both `origin/main` and local `main` equal the intended SHA. Stop if they differ, rather than treating a later `main` commit as the release commit.
3. Wait for the `Build and test` job in workflow `CI` for the exact intended SHA to pass. Stop on failure and report the run URL and SHA.
4. Immediately before tagging, fetch and confirm that `main` is checked out, `origin/main` and `HEAD` still equal the intended SHA, and the working tree is clean. Confirm the tag is still absent locally and on `origin`, and that GitHub still has no release for it. Then create an annotated tag at that SHA and push it:

   ```sh
   git tag -a v<version> <intended-sha> -m v<version>
   git push origin v<version>
   ```

5. Confirm the tag still names the intended commit and create the release without uploaded binary assets:

   ```sh
   gh release create v<version> --verify-tag --generate-notes
   ```

If a push, CI run, tag push, or release creation fails, stop. Report the intended commit SHA, tag state, relevant run or error URL, and the last completed step so the user has a recovery point. Do not retry a publication step or alter a tag without fresh user direction.

## Report

Report the version, commit SHA, tag, GitHub release URL, and that the release contains no uploaded binary assets.
