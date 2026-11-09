#!/bin/bash
# Runs an ordo-one/benchmark executable under Callgrind, speaking ordo-one/benchmark's protocol on
# standard input and output.
#
# The executable reads requests from descriptor 0 and writes replies to descriptor 3, which is the
# original standard output; its own output and Valgrind's go to standard error and a log file, so
# nothing else reaches the protocol stream. The cache geometry is fixed rather than detected, so
# the counts do not depend on the host's processor.
#
# With "native" as the fifth argument the executable runs without Valgrind, under the same shim,
# for the metrics ordo-one/benchmark counts itself (allocations, retains), which don't need the
# simulation and would add their hooks' instructions to it. Native runs preload ordo-one's
# interposers too, as its plugin does.
#
# Usage: run-benchmarks.sh <prefix provision.sh installed under> <executable> <dump directory>
#        [measured iterations per benchmark] [callgrind | native]
set -euo pipefail
prefix=$1
executable=$2
dumps=$3
iterations=${4:-}
mode=${5:-callgrind}
rm -rf "$dumps"
mkdir -p "$dumps"
exec 3>&1 1>&2
export LD_PRELOAD="$prefix/perfshim.so"
export SWIFT_DETERMINISTIC_HASHING=1
if [ -n "$iterations" ]; then export BENCHMARK_HARNESS_ITERATIONS="$iterations"; fi
if [ "$mode" = native ]; then
    # ordo-one/benchmark's plugin preloads its interposers from beside the executable, as here:
    # on Linux, allocations and (with Swift 6.3) retains and releases are counted only through them.
    directory=$(dirname "$executable")
    for library in libMallocInterposerSwift.so libSwiftRuntimeInterposerSwift.so; do
        if [ -f "$directory/$library" ]; then LD_PRELOAD="$directory/$library:$LD_PRELOAD"; fi
    done
    exec "$executable" --input-fd 0 --output-fd 3 --quiet true
fi
exec "$prefix/valgrind/bin/valgrind" \
    --tool=callgrind \
    --cache-sim=yes --branch-sim=yes \
    --I1=32768,8,64 --D1=32768,8,64 --LL=8388608,16,64 \
    --collect-atstart=no --instr-atstart=no --toggle-collect='__swift_run_job(*' \
    --callgrind-out-file="$dumps/callgrind.out" \
    --log-file="$dumps/valgrind.log" \
    "$executable" --input-fd 0 --output-fd 3 --quiet true
