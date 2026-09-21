#!/bin/bash
#
# This source file is part of the Swift.org open source project
#
# Copyright (c) 2026 Apple Inc. and the Swift project authors
# Licensed under Apache License v2.0 with Runtime Library Exception
#
# See https://swift.org/LICENSE.txt for license information
# See https://swift.org/CONTRIBUTORS.txt for Swift project authors
#
set -euo pipefail

case "${1:-}" in
  prepare)
    test -z "$(git status --porcelain)" || { echo 'A clean checkout is required.' >&2; exit 1; }
    git fetch --no-tags origin +refs/heads/main:refs/remotes/origin/main
    original_head=$(git rev-parse refs/remotes/origin/main)
    test "$(git rev-parse HEAD)" = "$original_head" || {
      echo 'main changed since checkout; retry with a fresh checkout.' >&2; exit 1;
    }
    git fetch --no-tags "${UPSTREAM_REPOSITORY:-https://github.com/swiftlang/swift-docc-plugin.git}" refs/heads/main
    upstream_head=$(git rev-parse FETCH_HEAD)
    if ! git -c commit.gpgsign=false rebase "$upstream_head"; then
      git rebase --abort
      echo 'Upstream rebase conflicted; remote main was not changed.' >&2
      exit 1
    fi
    printf 'original_head=%s\nupstream_head=%s\n' "$original_head" "$upstream_head" >> "${GITHUB_OUTPUT:?GITHUB_OUTPUT must name an output file}"
    ;;
  publish)
    : "${ORIGINAL_HEAD:?Missing original main revision}"
    : "${UPSTREAM_HEAD:?Missing tested upstream revision}"
    test -z "$(git status --porcelain)" || { echo 'Validation modified tracked inputs; refusing to push.' >&2; exit 1; }
    git merge-base --is-ancestor "$UPSTREAM_HEAD" HEAD
    if test "$(git rev-parse HEAD)" != "$ORIGINAL_HEAD"; then
      git push "--force-with-lease=refs/heads/main:$ORIGINAL_HEAD" origin HEAD:refs/heads/main
    else
      echo 'Already up to date.'
    fi
    ;;
  *) echo 'Usage: rebase-upstream.sh prepare|publish' >&2; exit 2 ;;
esac
