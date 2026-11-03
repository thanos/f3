# Feature matrix

Status values: `implemented`, `not implemented`, `untested`. A fixture can contain a feature this library does not read. That is not support.

The local Elixir run is recorded in [test-reports/stage-0.md](test-reports/stage-0.md). CI on macOS arm64 and Linux x86_64 is configured and has not been run.

| Capability | Status | Evidence |
| --- | --- | --- |
| Open and close a local file | implemented | `F3.IO.Local`, contract tests |
| Open and close an in-memory binary | implemented | `F3.IO.Memory`, contract tests |
| Positioned read capped by the caller | implemented | `pread/3` tests |
| Idempotent close, error after close | implemented | contract tests |
| Wire version constants 0.1 | implemented | `F3.Format`, doctests |
| Reject every other wire version | implemented | `F3.Format.compatible?/2` only; no file parser yet |
| Postscript decode and bounds checks | not implemented | Stage 1 |
| FlatBuffers footer | not implemented | Stage 1 |
| Arrow schema, row groups, IOUnits, EncUnits | not implemented | types exist, `F3.schema/1` and `F3.metadata/1` return `:not_implemented` |
| Read rows | not implemented | `F3.read/2` |
| Lazy stream | not implemented | `F3.stream/2` returns an error and does not build a stream |
| Columnar batch and `to_rows/1` | not implemented | `F3.Batch` struct only |
| Write | not implemented | `F3.Writer` |
| Projection, checksum verification | not implemented | categories reserved on `F3.Error` |
| `CASCADE` / Vortex decode | not implemented | fixtures may contain it |
| `CUSTOM_WASM` decode or execution | not implemented | disabled; no interpreter is linked |
| Dictionary, Zstd, Lz4, nested types | not implemented as a reader | present only if the manifest lists a fixture |
| Optional NIF version probe | implemented when `F3_BUILD_NATIVE=1` | macOS arm64, rustc 1.97.1, Elixir 1.20.2 / OTP 28: `{:ok, {"f3_native", "0.0.1"}}`. Default build: `{:error, :native_unavailable}`. Linux not run. |
| macOS arm64 local Elixir tests | passed | Elixir 1.20.2, OTP 28.3.1, `mix test`: 15 passed. See [test-reports/stage-0.md](test-reports/stage-0.md). |
| Linux x86_64 CI | configured, not run | `.github/workflows/ci.yml` job `test (ubuntu-latest)` |
| macOS arm64 CI | configured, not run | `.github/workflows/ci.yml` job `test (macos-14)` |
| Linux arm64 | untested | no job |
| Upstream Intel Debian 12 | untested by this repo | upstream's own claim, not reproduced here |
