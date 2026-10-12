# Contributing to chunkmap

Thanks for taking the time to contribute!

## Development setup

1. Install [Zig 0.14.1](https://ziglang.org/download/) (the version is pinned in `build.zig.zon` and CI).
2. Install Python 3.9+ (only needed for the demo-data generator and the end-to-end test).

```bash
zig build test --summary all                 # unit tests (every module has inline tests)
zig build -Doptimize=ReleaseFast             # optimized binary in zig-out/bin
python scripts/make_demo_data.py demo-data   # 273 MiB reproducible "messy disk"
./zig-out/bin/chunkmap scan demo-data --html report.html
python scripts/e2e.py zig-out/bin/chunkmap   # end-to-end assertions on the JSON report
```

## Guidelines

- Keep the binary dependency-free: only the Zig standard library.
- Every behavioural change needs a test next to the code it changes (`test "..." {}` blocks).
- Run `zig fmt src build.zig` before committing; CI checks formatting.
- The HTML report must stay a single offline file — no external fonts, scripts or CDNs.
- Report changes that alter the JSON shape must bump `schema_version` in `src/report/model.zig`.

## Regenerating the docs

```bash
./zig-out/bin/chunkmap scan demo-data -q --html docs/index.html --json docs/sample-report.json
./zig-out/bin/chunkmap scan demo-data -q --color always --top 4 | python scripts/ansi_to_svg.py > docs/terminal.svg
```

## Releasing

Push a tag `vX.Y.Z`; the release workflow cross-compiles all six targets, packages them with checksums and publishes a GitHub release.
