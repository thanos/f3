# Feature matrix

Status values: `implemented`, `not implemented`, `untested`. A fixture can contain a feature this library does not read. That is not support.

The local Elixir runs are recorded in [test-reports/stage-0.md](test-reports/stage-0.md) and [test-reports/stage-1.md](test-reports/stage-1.md). CI on macOS arm64 and Linux x86_64 is configured and has not been run.

| Capability | Status | Evidence |
| --- | --- | --- |
| Open and close a local file | implemented | `F3.IO.Local`, contract tests |
| Open and close an in-memory binary | implemented | `F3.IO.Memory`, contract tests |
| Positioned read capped by the caller | implemented | `pread/3` tests |
| Idempotent close, error after close | implemented | contract tests |
| Wire version constants 0.1 | implemented | `F3.Format`, doctests |
| Reject every other wire version | implemented | `F3.Postscript` returns `:unsupported_version` |
| Postscript decode and bounds checks | implemented | `F3.Postscript`, `test/f3/postscript_test.exs` |
| FlatBuffers footer | implemented | `F3.FlatBuffer`, `F3.Footer`; golden JSON matches the upstream reader |
| Arrow schema, row groups, IOUnits, EncUnits | implemented | `F3.schema/1` and `F3.metadata/1` on the eight fixtures |
| Read rows | not implemented | `F3.read/2` |
| Lazy stream | not implemented | `F3.stream/2` returns an error and does not build a stream |
| Columnar batch and `to_rows/1` | not implemented | `F3.Batch` struct only |
| Write | not implemented | `F3.Writer` |
| Projection | not implemented | reserved |
| Checksum verification | not implemented | both checksums are reported; they are not recomputed |
| `CASCADE` / Vortex decode | not implemented | encoding id is reported as `:cascade` |
| `CUSTOM_WASM` decode or execution | not implemented | encoding id and Wasm pointers are reported; bytes are not read |
| Dictionary, Zstd, Lz4, nested types | metadata only | local dictionary, zstd, lz4, list, and struct are decoded from the footer; values are not |
| Optional NIF version probe | implemented when `F3_BUILD_NATIVE=1` | macOS arm64, rustc 1.97.1, Elixir 1.20.2 / OTP 28: `{:ok, {"f3_native", "0.0.1"}}`. Default build: `{:error, :native_unavailable}`. Linux not run. |
| macOS arm64 local Elixir tests | passed | Elixir 1.20.2, OTP 28.3.1, `mix test`: 30 passed. See [test-reports/stage-1.md](test-reports/stage-1.md). |
| Linux x86_64 CI | configured, not run | `.github/workflows/ci.yml` job `test (ubuntu-latest)` |
| macOS arm64 CI | configured, not run | `.github/workflows/ci.yml` job `test (macos-14)` |
| Linux arm64 | untested | no job |
| Upstream Intel Debian 12 | untested by this repo | upstream's own claim, not reproduced here |
