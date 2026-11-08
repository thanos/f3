# Stage 5 test report

Recorded 2026-11-07 after the commands below. GitHub Actions has not been run from this machine. The required workflow is still `mix ci` plus the native decode job. This stage did not add a benchmark gate or a MinIO service.

## Environment

| Tool | Version |
| --- | --- |
| Host | Darwin arm64 |
| Elixir | 1.20.2, compiled with Erlang/OTP 28 |
| OTP | 28 |
| Native stamp | `0` for the benchmark and for `mix ci` |
| Upstream | `bd92506447dc1333820cfe9a34ebbf497fe0219e` |

The committed `.f3` fixtures were not regenerated. Hex was not published. Version stayed `0.0.1`.

## HTTP

`mix test test/f3/io/http_test.exs` — 12 passed. The run excluded `:minio` and `:native`. `F3_MINIO` was unset, so the MinIO tag was not run. The tests spoke HTTP to a `:gen_tcp` server in the test process. A full read of `small.f3` matched the local schema, metadata, and `F3.read/2` result. A ranged pread was capped. A missing object was `:not_found`. A redirect was refused. `F3.schema/1` on the local fixture did not contact that server.

## Benchmark

`/usr/bin/time -l mix run scripts/bench.exs` exited 0. `native_stamp` was `0`. Eight fixtures returned `:native_unavailable`. `custom_wasm.f3` returned `:unsupported_encoding`. `parquet-cli` and a `pyarrow` binary were not on `PATH`, so the script printed `parquet comparison: skipped`. It did not download data.

`/usr/bin/time -l` printed `maximum resident set size` 109854720 and `peak memory footprint` 97747616. The script printed `ps_rss_kb: 107136` from `ps`. That is the resident set `ps` reported, not the `time` peak.

`batch_size` stayed 8192. Projection stayed every column. A chunk is still one `pread/3`. This run does not name a defect in those defaults.

The script's stdout is quoted in `docs/tutorials/09-performance-and-what-remains-experimental.md`.

## Packaging

`mix.exs` `files` includes `native/f3_write/src`, `native/f3_write/build.ex`, `native/f3_write/Cargo.toml`, and `native/f3_write/rust-toolchain.toml`. It does not list `priv/native`, `tmp/`, or a built helper. Precompiled NIFs stay off. `NOTICE` records the license fields read from the Vortex, Arrow, Wasmtime, and `fff-poc` crate files.

## Required checks

`mix ci` passed. Format check, compile with warnings as errors, Credo strict, and docs passed. Tests: 100 passed (3 doctests, 97 tests), 16 excluded. Coverage 90.53%. The excluded tags were `:native` and `:minio`. The beam was the rust-free stub (`native_stamp` 0).
