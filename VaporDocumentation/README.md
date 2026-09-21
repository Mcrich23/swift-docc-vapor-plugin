# Vapor documentation in this fork

This fork adds `generate-vapor-documentation` and `preview-vapor-documentation`.
The standard DocC commands remain upstream's implementation.

```sh
swift package generate-vapor-documentation --target Server \
  --vapor-routes https://api.example.com --vapor-endpoints-only
```

See [Documenting Vapor Routes](Documentation/Documenting%20Vapor%20Routes.md) for
registration support, exclusion comments, and type selection.

## Isolation from upstream

All feature sources, commands, tests, documentation, and maintenance scripts live
here. `Package.swift` has a single appended registration block; it is the only
modified upstream file. The fork's workflow is `.github/workflows/vapor-sync-upstream.yml`.

The two Vapor commands share one fork-owned runner under `Plugins/Shared`.
Relative symlinks let that runner use upstream's plugin helpers and argument
parser without copying or editing them. An upstream change to those internal
APIs may require an update here; the scheduled sync tests the commands before
publishing. Keep feature changes in this folder and the manifest registration
together.

Run `bash VaporDocumentation/Scripts/test.sh` for upstream tests, Vapor unit and
integration tests, source checks, and rebase safety tests. The integration test
invokes SwiftPM directly against a small fixture; it does not copy upstream's
test harness or change its test manifest. Its build output is in the root
`.build/` directory.

## Daily upstream rebase

The workflow runs daily at **10:23 UTC** and can also be started manually. It
fetches `swiftlang/swift-docc-plugin` main, rebases this fork's commits on top,
runs the tests, then pushes with a lease against the exact original main revision.
A merge conflict, test failure, dirty checkout, or concurrent change to remote
main stops publication. Conflicts are never resolved automatically.

To activate it, push local main to the fork and enable Actions there. This workflow
is restricted to `Mcrich23/swift-docc-plugin`. Main's repository rules must allow
the workflow identity to force-push. The built-in token has contents-write access;
if upstream changes workflow files and GitHub rejects the push, configure the
optional `SYNC_FORK_TOKEN` secret with repository contents and workflows write
permissions (a classic token requires `repo` and `workflow`). No token belongs in
source control. Public repositories may have schedules disabled after 60 days of
inactivity; see [GitHub's schedule documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#schedule).

After a successful automated rebase, existing local branches have the old history.
Fetch and inspect before updating a local checkout; preserve any local work.

<!-- Copyright (c) 2026 Apple Inc and the Swift Project authors. All Rights Reserved. -->
