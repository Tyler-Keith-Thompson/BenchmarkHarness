#!/bin/bash
# Runs an ordo-one/benchmark executable under Callgrind, speaking ordo-one/benchmark's protocol on
# standard input and output.
#
# The executable reads requests from descriptor 0 and writes replies to descriptor 3, which is the
# original standard output; its own output and Valgrind's go to standard error and a log file, so
# nothing else reaches the protocol stream. The cache geometry is fixed rather than detected, so
# the counts do not depend on the host's processor.
#
# Usage: run-benchmarks.sh <executable> <dump directory>
set -euo pipefail
executable=$1
dumps=$2
rm -rf "$dumps"
mkdir -p "$dumps"
exec 3>&1 1>&2
export LD_PRELOAD=/opt/perfshim.so
export SWIFT_DETERMINISTIC_HASHING=1
exec /opt/valgrind/bin/valgrind \
    --tool=callgrind \
    --cache-sim=yes --branch-sim=yes \
    --I1=32768,8,64 --D1=32768,8,64 --LL=8388608,16,64 \
    --collect-atstart=no \
    --callgrind-out-file="$dumps/callgrind.out" \
    --log-file="$dumps/valgrind.log" \
    "$executable" --input-fd 0 --output-fd 3 --quiet true
