# Stage 0 test report

Recorded 2026-11-03 after the commands below. CI has not run. Linux x86_64 is configured in `.github/workflows/ci.yml` and is untested here.

## Environment

| Tool | Version |
| --- | --- |
| Host | Darwin arm64 |
| Elixir | 1.20.2, compiled with Erlang/OTP 28 |
| OTP | 28, erts 16.2 |
| NIF Rust | rustc 1.97.1, host `aarch64-apple-darwin` |
| Fixture Rust | `nightly-2025-02-24`, rustc 1.87.0-nightly (f8a913b13 2025-02-23), `aarch64-apple-darwin` |
| Upstream | `bd92506447dc1333820cfe9a34ebbf497fe0219e` |

`rustup` on this machine is an x86_64 binary running under emulation. The toolchains it installed and the `rustc` processes used above are aarch64.

## Commands

Default build, no `F3_BUILD_NATIVE`:

```text
mix test
15 passed (3 doctests, 12 tests)
mix format --check-formatted
mix docs
```

`mix format --check-formatted` exited 0. `mix docs` wrote `doc/index.html`.

Optional NIF, then a return to the default build:

```text
F3_BUILD_NATIVE=1 mix compile --force --warnings-as-errors
F3_BUILD_NATIVE=1 mix test test/f3/contract_test.exs
12 passed (3 doctests, 9 tests)
```

`priv/native/f3_native.so` is a Mach-O arm64 dylib. `F3.Native.info/0` returned `{:ok, {"f3_native", "0.0.1"}}` under that test. A later `mix compile --force` without the flag restored the default beam, and `mix test` passed again with `available?/0` false.

Fixture generation:

```text
scripts/fixtures/generate.sh
```

Eight files were written: `small.f3`, `nullable.f3`, `wide.f3`, `multi_row_group.f3`, `compressed_zstd.f3`, `compressed_lz4.f3`, `dictionary.f3` (`LocalDictionary`), `nested.f3` (struct and `list<int32>`). `custom_wasm.f3` was skipped. `fff-ude-example-fff` failed to build for `wasm32-wasip1` because clang could not find `stdlib.h`, `string.h`, `stdio.h`, and `assert.h` while compiling `zstd-sys`. The manifest records that reason. No Wasm fixture was invented.

`mix run examples/tutorial_02.exs` printed the tail of the committed `small.f3` (4168 bytes, SHA-256 `6f1ff9d7202c3f0d8f910a4ef154ba195cd225804d261ca752339cc8fc123a13`). That output is copied into tutorial 2.

## Not measured

No throughput, RSS, or scheduler numbers. Linux x86_64 and Linux arm64 were not executed. The GitHub Actions file is present and has not been run from this machine.

## Implemented

The Mix library at the repository root opens a local path or an in-memory binary and closes that handle. `lib/f3.ex` refuses schema, metadata, read, stream, and inspect with `:not_implemented`. `lib/f3/writer.ex` refuses open, write, and close the same way. `lib/f3/format.ex` holds the pinned constants and `compatible?/2`. `lib/f3/io/local.ex` and `lib/f3/io/memory.ex` implement size, positioned read, and idempotent close. `lib/f3/error.ex` is the error struct. Schema, metadata, row group, and batch structs exist and are not filled from a file.

`native/f3_native` is a stable-Rust version probe. It is compiled only when `F3_BUILD_NATIVE=1`. It does not link `fff-poc`.

`scripts/fixtures/generate.sh` clones the pinned upstream commit, builds `FileWriter` from `scripts/fixtures/generator/src/main.rs` with that checkout's `Cargo.lock`, and writes `test/fixtures/*.f3` plus `test/fixtures/manifest.json`.

## Public API

`F3.open/2` and `F3.close/1` work. The other public calls do not read the format:

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:error, %F3.Error{category: :not_implemented}} = F3.schema(file)
:ok = F3.close(file)
{:error, %F3.Error{category: :closed}} = F3.schema(file)
```

`F3.Format.compatible?(0, 1)` is true. Any other pair is false. `F3.Native.available?/0` is false unless the module was compiled with the native flag. There is no application callback.

## Documentation

Tutorials 1 and 2 are technically reviewed. The hex dump in tutorial 2 matches the committed `small.f3` (4168 bytes, SHA-256 `6f1ff9d7202c3f0d8f910a4ef154ba195cd225804d261ca752339cc8fc123a13`). `examples/tutorial_01.exs` and `examples/tutorial_02.exs` run under `mix test`. Tutorials 3–9 are backlog entries in `docs/tutorials/README.md` and have no article files. `docs/tutorials/publication-plan.md` does not schedule or post anything. Compatibility, architecture, the feature matrix, security notes, and ADR 0001 are in `docs/`.

## Next stage

Stage 1 is a postscript decoder checked against these fixtures: bounds, magic, version, and truncation, with no FlatBuffers walk and no row reader. The footer checksum and the out-of-band column metadata stay unread until that decoder exists. Regenerating fixtures can change bytes because the upstream writer samples with `thread_rng`, so a new manifest has to replace the tutorial 2 dump from a new `mix run examples/tutorial_02.exs`.
