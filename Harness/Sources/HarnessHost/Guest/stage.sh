#!/bin/bash
# Copies the shared source tree into the guest's own filesystem, so building and resolving
# dependencies never write to the host's checkout. Build products, version control and Bazel's
# output links are left behind. Copied files keep their modification times, so incremental builds
# in a persistent scratch directory stay incremental.
#
# When the staged files differ in name from the last staging for the scratch directory (a file
# added, removed or renamed), SwiftPM's cached build plans there are deleted, so the next build
# plans again and compiles every source file; compiled products are kept. A cached plan that
# predates a new file otherwise leaves the file out of the build.
#
# Usage: stage.sh <shared source directory> <destination> <scratch directory>
set -euo pipefail
source=$1
destination=$2
scratch=$3
rm -rf "$destination"
mkdir -p "$destination"
tar -C "$source" \
    --exclude='./.git' --exclude='.build' --exclude='.swiftpm' --exclude='./bazel-*' \
    --exclude='.benchmarkBaselines' \
    -cf - . | tar -C "$destination" -xf -

mkdir -p "$scratch"
listing=$(cd "$destination" && find . \( -type f -o -type l \) | LC_ALL=C sort | cksum)
if [ "$(cat "$scratch/.harness-staged-files" 2>/dev/null)" != "$listing" ]; then
    rm -f "$scratch"/*.yaml "$scratch"/*/*/description.json "$scratch"/*/*/plugin-tools-description.json
    echo "$listing" > "$scratch/.harness-staged-files"
fi
