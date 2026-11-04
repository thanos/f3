# Stage 2 test report

Recorded 2026-11-04 after the commands below. GitHub Actions has not been run from this machine. Linux x86_64 is configured as a required decode job and is untested here.

## Environment

| Tool | Version |
| --- | --- |
| Host | Darwin arm64 |
| Elixir | 1.20.2, compiled with Erlang/OTP 28 |
| OTP | 28, erts 16.2 |
| Decoder Rust | 1.93.0-nightly (`nightly-2025-11-15`, commit b6d7ff3aa, 2025-11-14), aarch64-apple-darwin |
| Upstream | `bd92506447dc1333820cfe9a34ebbf497fe0219e` |
| Vortex | `c0d89a66cbaa542bd9aa277cfdf52f2728c4b37a` |
| Arrow | `arrow-array` 53.3.0 |

The eight `.f3` fixtures were not regenerated. Their SHA-256 values are still the ones in `test/fixtures/manifest.json`. `small.f3` is 4168 bytes, SHA-256 `6f1ff9d7202c3f0d8f910a4ef154ba195cd225804d261ca752339cc8fc123a13`.

## Toolchain spike

Stable rustc 1.97.1 `cargo check` of `native/f3_native` stopped in `fastlanes` on `#![feature(generic_const_exprs)]`.

`nightly-2025-02-24` (rustc 1.87.0-nightly) stopped before compiling Vortex. Rustler 0.38.0 declares `rust-version = "1.91"`. A fresh resolve also selected `croaring` 2.9.0, which wants rustc 1.95.

rustc 1.101.0-nightly (2026-10-15) compiled Vortex's feature gates, then failed in `vortex-fastlanes` because `ArrayChunks::into_remainder` no longer returns `Option`. That signature changed in rust-lang/rust#149127, merged 2025-11-21. The same nightly also needed `chrono = "=0.4.39"` so `arrow-arith` 53.3.0 could compile. `chrono` 0.4.45 adds `Datelike::quarter`, which collides with Arrow's own `quarter`.

`nightly-2025-11-15` is after Rust 1.91 and before that standard-library change. With `croaring = "=2.1.0"` (the upstream lock) and `chrono = "=0.4.39"`, `cargo check` finished. `F3_BUILD_NATIVE=1 mix compile --force` produced an arm64 `priv/native/f3_native.so`. `nm -gU` on that file showed no `fff-poc` and no mimalloc symbols.

The first uncompressed int64 EncUnit of `small.f3` (offset 0, size 1664) decoded to the values 1, 2, and 3.

## Commands

```text
mix format
mix credo --strict
mix test
66 passed (3 doctests, 63 tests), 4 excluded
mix test --cover
66 passed, coverage 92.05%
F3_BUILD_NATIVE=1 mix test --only native
4 passed, 65 excluded
```

`mix test` and `mix test --cover` compile without Rust. `F3_BUILD_NATIVE=1 mix compile --force` in the test environment is what loads the NIF for `--only native`. The default beam used by `mix test` does not contain it.

One local run of the pinned `FileReaderV2` (`fff-poc` example `dump_rows`, built with `nightly-2025-02-24`) wrote `test/fixtures/golden/*_rows.json` for seven fixtures. `dictionary.f3` panics in that reader with `Incorrect type of indices`. The native test compares those seven files to the golden JSON and all eight files to the manifest rows. CI does not regenerate the `.f3` files.

## Not measured

No throughput, latency, or RSS. The eight fixtures are smaller than one encoding unit, so they cannot show dirty-scheduler delay. The NIF is still scheduled `DirtyCpu`. Linux x86_64 and Linux arm64 were not executed. The required `decode` job in `.github/workflows/ci.yml` installs `nightly-2025-11-15` on `macos-14` and `ubuntu-latest` and runs `mix test --only native`. The informational native job stays on stable Rust and is expected to fail.

## Implemented

`F3.read/2` returns `{:ok, [F3.Batch.t()]}`. `F3.stream/2` returns a stream and does not pread until the first pull. `Enum.take/2` stops further reads. The caller owns `close/1`. Options are `columns:`, `row_groups:`, and `batch_size:` (default 8192). One NIF call decodes a whole EncUnit. Elixir slices it.

The eight fixtures round-trip, including nullable values, a nullable struct, a list of int32 with an empty list, a local dictionary, zstd, and lz4. `CUSTOM_WASM` and a shared dictionary are `:unsupported_encoding` and are not executed. Bool and plain binary are not in the fixtures.

A wiped EncUnit returns `{:error, %F3.Error{category: :corrupt}}`. The caller stays alive. Chunk checksums are checked only when the footer field is present. These fixtures store none. Postscript checksums stay reported and unverified.

## Next

Stage 3 is Wasm. Execution stays off.
