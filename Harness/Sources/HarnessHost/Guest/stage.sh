#!/bin/bash
# Copies the shared source tree into the guest's own filesystem, so building and resolving
# dependencies never write to the host's checkout. Build products, version control and Bazel's
# output links are left behind. Copied files keep their modification times, so incremental builds
# in a persistent scratch directory stay incremental.
#
# Usage: stage.sh <shared source directory> <destination>
set -euo pipefail
source=$1
destination=$2
rm -rf "$destination"
mkdir -p "$destination"
tar -C "$source" \
    --exclude='./.git' --exclude='.build' --exclude='.swiftpm' --exclude='./bazel-*' \
    --exclude='.benchmarkBaselines' \
    -cf - . | tar -C "$destination" -xf -
