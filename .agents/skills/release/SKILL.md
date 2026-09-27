---
name: release
description: Prepare and publish a GitHub release for the zlap Zig library when the user requests a release.
---

# Release zlap

Use this skill for a requested GitHub release of zlap. zlap is a Zig library and releases have no binary artifacts.

## Prepare

1. Inspect the current branch, working-tree cleanliness, and whether local `main` is up to date with `origin/main`. Stop and resolve or ask for direction if the release cannot be based on a clean, current `main`.
2. If the user specifies a target SemVer, validate it. For an explicit release request, update the root `build.zig.zon` version and align `examples/build.zig.zon` when it declares a version. For a preparation-only request, report required manifest edits without applying them. Otherwise, use the root manifest version. The intended version must be valid SemVer. When edits are authorized, permit only these intended manifest changes.
3. Run the release checks:

   ```sh
   zig build test
   zig build
   (cd examples && zig build fmt)
   (cd examples && zig build)
   ```

4. Set the tag name to `v<version>`. Confirm it is absent locally and on `origin`, and that GitHub has no release for it. Never move, replace, or reuse an existing published tag.

## Publish

An explicit release request authorizes the needed commit, push, tag, and GitHub release. A request only to prepare or check a release is read-only and stops before publication.

1. If the version manifests changed, commit and push only those changes to `main` with a Conventional Commit message, then record that commit as the intended SHA. If they did not change because the target version is already present, use the existing `HEAD` as the intended SHA. Do not create an empty commit.
2. Wait for the `Build and test` job in the GitHub Actions workflow `CI` for the exact intended SHA to pass. Stop on failure and report the run URL and SHA.
3. Immediately before tagging, fetch and confirm `origin/main` and `HEAD` still equal the intended SHA and the working tree is clean. Then create an annotated tag at that SHA and push it:

   ```sh
   git tag -a v<version> <intended-sha> -m v<version>
   git push origin v<version>
   ```

4. Confirm the tag still names the intended commit and create the release without assets:

   ```sh
   gh release create v<version> --verify-tag --generate-notes
   ```

If a push, CI run, tag push, or release creation fails, stop. Report the intended commit SHA, tag state, relevant run or error URL, and the last completed step so the user has a recovery point. Do not retry a publication step or alter a tag without fresh user direction.

## Report

Report the version, commit SHA, tag, GitHub release URL, and that the release contains no uploaded binary assets.
