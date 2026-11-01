# BenchmarkHarness

`benchmark-harness` gives your [ordo-one/benchmark](https://github.com/ordo-one/benchmark)
benchmarks numbers that don't move when the machine is busy: it counts the work each iteration
does (instructions, cache misses, mispredicted branches) in a simulation instead of timing it, and
writes the counts as an ordinary ordo-one baseline.

## Requirements

- macOS 26 on Apple silicon (the tool runs the benchmarks in a Linux virtual machine), or Linux
  on aarch64 (the tool runs them on the host, for example a CI runner).
- Swift 6.3.
- A package whose benchmarks use ordo-one/benchmark. Nothing in them changes.

## Install

On macOS, build the tool and sign it with the virtualization entitlement:

```sh
git clone https://github.com/Tyler-Keith-Thompson/BenchmarkHarness && cd BenchmarkHarness/Harness && swift build -c release --product benchmark-harness && codesign --force --sign - --entitlements harness.entitlements .build/release/benchmark-harness
```

On Linux:

```sh
git clone https://github.com/Tyler-Keith-Thompson/BenchmarkHarness && swift build -c release --package-path BenchmarkHarness/Harness --product benchmark-harness
```

Either way the tool is `BenchmarkHarness/Harness/.build/release/benchmark-harness`. Put it on your
`PATH`, or call it by that path.

## Record and compare

From the package that holds your benchmarks, record a baseline, make your change, record another,
and compare them with ordo-one's own command:

```sh
benchmark-harness baseline update before
# … change the code …
benchmark-harness baseline update after
swift package benchmark baseline compare before after
```

Add `--package-path <directory>` to point at the benchmarks package from elsewhere, and
`--target`, `--filter` or `--skip` to run fewer benchmarks, as with `swift package benchmark`.
Baselines are written to `.benchmarkBaselines/`, where `swift package benchmark baseline check`
reads them too.

Each baseline records:

| Metric | Counts |
|---|---|
| Instructions | Instructions executed |
| L1 Miss Sum | Level-1 instruction and data cache misses, on a 32 KiB 8-way cache with 64-byte lines |
| Last-level Miss Sum | Last-level cache misses, on an 8 MiB 16-way cache |
| Mispredicted Branch | Mispredicted conditional and indirect branches |
| Cycle Estimation | `Instructions + 10 × (L1 misses + mispredicted branches) + 100 × last-level misses` |

It also records each benchmark's allocation, retain and release counts and custom metrics, as
`swift package benchmark` would. Compare baselines recorded on the same kind of machine: counts
depend on the processor architecture and the Swift toolchain.

## In CI

On a GitHub Actions Linux runner, record the pull request's counts and compare them with a
baseline committed from `main`:

```yaml
jobs:
  benchmarks:
    runs-on: ubuntu-26.04-arm
    container: swift:6.3
    steps:
      - uses: actions/checkout@v7
      - name: Install benchmark-harness
        run: |
          git clone --depth 1 https://github.com/Tyler-Keith-Thompson/BenchmarkHarness /tmp/BenchmarkHarness
          swift build -c release --package-path /tmp/BenchmarkHarness/Harness --product benchmark-harness
      - name: Record and compare
        run: |
          /tmp/BenchmarkHarness/Harness/.build/release/benchmark-harness baseline update pull-request
          swift package benchmark baseline compare main pull-request
```

Commit the `main` baseline by running `benchmark-harness baseline update main` on the same kind
of machine and committing `.benchmarkBaselines/`.

## Troubleshooting

**The first run takes several minutes.** It downloads Valgrind (and on macOS a Linux kernel and
Swift image) and builds Valgrind, once. Later runs reuse the cache in
`~/Library/Caches/BenchmarkHarness` on macOS and `~/.cache/BenchmarkHarness` on Linux. On Linux,
building Valgrind needs `make`, `gcc`, the C library headers, `bzip2` and `patch`; run as root
with `apt-get`, as in a `swift` container, the tool installs them itself.

**`Waiting for another run on … (process N)`.** Another run on the same checkout is using its
build products; this one starts when process N finishes. Stop that process to start now.

**Measuring is slow.** Simulation runs roughly fifty times slower than native code, so the tool
measures three iterations of each benchmark (`--iterations`) and runs several benchmarks at once
(`--jobs`). Narrow a run with `--target` or `--filter` while iterating.

**On macOS, the virtual machine won't start.** The tool must be signed with
`harness.entitlements`, as in the install command above; rebuilding it removes the signature.

## How it works

[docs/HowItWorks.md](docs/HowItWorks.md) explains the measurement windows, the virtual machine,
the Valgrind build and why two runs agree. The modules that read Callgrind's dumps and write
ordo-one's baselines are also a library: [docs/Library.md](docs/Library.md), with the
[API reference](https://tyler-keith-thompson.github.io/BenchmarkHarness/documentation/).

## Development

Bazel is the development build; SwiftPM is the published package. Both are generated from
`scripts/modules.py`.

| Command | Does |
|---|---|
| `just test` | Build and run every test |
| `just verify` | The tests under Bazel and under SwiftPM |
| `just modules` | Regenerate `Package.swift` and every `BUILD.bazel` |
| `just docs` | The DocC site into `.build/docs` |
| `just bench` | The benchmarks (`Benchmarks/README.md`) |
| `just bench-simulated` | The benchmarks' simulated counts, as the `simulated` baseline |
| `just bench-simulated-compare` | Simulated counts now, compared against `simulated` |
| `just harness` | Build and sign the tool |
| `just harness-test` | The tool's tests |
| `just generate` | An Xcode project from the Bazel graph |

`AGENTS.md` describes the layout, the workflow and the house rules in full.

## License

MIT. See `LICENSE`.
