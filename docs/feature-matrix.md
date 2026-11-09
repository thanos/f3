# Feature matrix

Status values: `implemented`, `not implemented`, `untested`. A fixture can contain a feature this library does not read. That is not support.

The local Elixir runs are recorded in [test-reports/stage-0.md](test-reports/stage-0.md), [test-reports/stage-1.md](test-reports/stage-1.md), [test-reports/stage-2.md](test-reports/stage-2.md), [test-reports/stage-3.md](test-reports/stage-3.md), [test-reports/stage-4.md](test-reports/stage-4.md), and [test-reports/stage-5.md](test-reports/stage-5.md). The required CI jobs are configured and have not been run from this machine.

| Capability | Status | Evidence |
| --- | --- | --- |
| Open and close a local file | implemented | `F3.IO.Local`, contract tests |
| Open and close an in-memory binary | implemented | `F3.IO.Memory`, contract tests |
| HTTP range read | implemented | `F3.IO.HTTP`. Opt-in. Redirects refused. `:minio` excluded unless `F3_MINIO=1` |
| Positioned read capped by the caller | implemented | `pread/3` tests |
| Idempotent close, error after close | implemented | contract tests |
| Wire version constants 0.1 | implemented | `F3.Format`, doctests |
| Reject every other wire version | implemented | `F3.Postscript` returns `:unsupported_version` |
| Postscript decode and bounds checks | implemented | `F3.Postscript`, `test/f3/postscript_test.exs` |
| FlatBuffers footer | implemented | `F3.FlatBuffer`, `F3.Footer`; golden JSON matches the upstream reader |
| Arrow schema, row groups, IOUnits, EncUnits | implemented | `F3.schema/1` and `F3.metadata/1` on the eight fixtures |
| Read rows | implemented when `F3_BUILD_NATIVE=1` | `F3.read/2` on the eight fixtures. Default build: `:native_unavailable` |
| Lazy stream | implemented when `F3_BUILD_NATIVE=1` | `F3.stream/2` does not pread until the first pull. `Enum.take/2` stops |
| Columnar batch and `to_rows/1` | implemented | `F3.Batch` stores columns. `to_rows/1` is the convenience zip |
| Write | implemented when `F3_BUILD_NATIVE=1` | `F3.Writer`. Local temp file, rename after `finish`. Default build: `:not_implemented` |
| Projection | implemented | `columns:` and `row_groups:`. Unknown name is `:invalid_projection` |
| Postscript checksum | reported, not verified | both u64 fields are stored |
| Chunk checksum | implemented when the footer field is present | XXH64 seed 0. The eight fixtures store none |
| `CASCADE` / Vortex decode | implemented when `F3_BUILD_NATIVE=1` | dirty CPU NIF. Does not link `fff-poc` |
| `CUSTOM_WASM` decode or execution | opt-in | Default `:off` is `:unsupported_encoding` and does not read the section. `wasm: :sandbox` runs Wasmtime 28 when `F3_BUILD_NATIVE=1`. `custom_wasm.f3` matches the manifest rows |
| Shared dictionary | refused | `:unsupported_encoding` |
| Local dictionary, Zstd, Lz4, nested types | implemented when `F3_BUILD_NATIVE=1` | round-trip of `dictionary.f3`, `compressed_zstd.f3`, `compressed_lz4.f3`, and `nested.f3` |
| Bool values | implemented when `F3_BUILD_NATIVE=1` | writer round trip. Not present in the eight fixtures |
| Plain binary values | untested | not a claimed writer type, and not present in the eight fixtures |
| Optional NIF | implemented when `F3_BUILD_NATIVE=1` | macOS arm64, rustc 1.93.0-nightly (`nightly-2025-11-15`), Elixir 1.20.2 / OTP 28. Default build: `{:error, :native_unavailable}`. Linux not run locally |
| macOS arm64 local Elixir tests | passed | Elixir 1.20.2, OTP 28.3.1. `mix test --cover` passes the 90% threshold. See [test-reports/stage-1.md](test-reports/stage-1.md). |
| Linux x86_64 CI | configured, not run | `.github/workflows/ci.yml` job `test (ubuntu-latest)` |
| macOS arm64 CI | configured, not run | `.github/workflows/ci.yml` job `test (macos-15)` |
| Linux arm64 | untested | no job |
| Precompiled NIF release | configured, not run | `.github/workflows/precompile.yml` on a `v*` tag. Targets: `aarch64-apple-darwin`, `x86_64-unknown-linux-gnu`. NIF version 2.17 |
| Hex publish | configured, not run | `.github/workflows/publish.yml` after that GitHub release. Requires the `HEX_API_KEY` secret |
| Upstream Intel Debian 12 | untested by this repo | upstream's own claim, not reproduced here |
