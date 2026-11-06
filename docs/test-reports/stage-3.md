# Stage 3 test report

Recorded 2026-11-04 after the commands below. GitHub Actions has not been run from this machine. Linux x86_64 is configured as a required decode job and is untested here.

## Environment

| Tool | Version |
| --- | --- |
| Host | Darwin arm64 |
| Elixir | 1.20.2, compiled with Erlang/OTP 28 |
| OTP | 28, erts 16.2 |
| Decoder Rust | 1.93.0-nightly (`nightly-2025-11-15`, commit b6d7ff3aa, 2025-11-14), aarch64-apple-darwin |
| Fixture Rust | `nightly-2025-02-24`, aarch64-apple-darwin, target `wasm32-wasip1` |
| WASI C toolchain | Homebrew `wasi-libc` 34 and `wasi-runtimes` 23.1.5. That formula upgraded Homebrew LLVM to 23.1.5, which compiled the C objects inside `zstd-sys`. The final `.wasm` link used rustc's linker |
| Upstream | `bd92506447dc1333820cfe9a34ebbf497fe0219e` |
| Wasmtime | 28.0.0, with `wasi-common` 28.0.0 |
| Vortex | `c0d89a66cbaa542bd9aa277cfdf52f2728c4b37a` |

The eight earlier `.f3` fixtures were not regenerated. `custom_wasm.f3` was added. It is 10_663_647 bytes, SHA-256 `70beae4fedc5825d3de83e0ff0a117712283138afcdfee610da7f6d800eb6c8b`. The embedded module is 10_661_135 bytes, so the hard module cap is 16 MiB. A 8 MiB cap would reject this file.

## Wasm build

The first link used Homebrew clang as `CARGO_TARGET_WASM32_WASIP1_LINKER`. `zstd-sys` compiled. The link failed:

```text
rust-lld: error: entry symbol not defined (pass --no-entry to suppress): _initialize
```

The retry kept `CC_wasm32_wasip1` on Homebrew clang and `WASI_SYSROOT=/opt/homebrew/opt/wasi-libc/share/wasi-sysroot`, and left the Wasm link to `nightly-2025-02-24`. That build finished. `fff-ude-example-fff.wasm` exports `FFFUDE_VERSION_1_0` and `decode_general_ffi`.

`tmp/upstream-f3/target/release/f3_fixture_gen` then wrote every fixture into `/tmp/f3-stage3-fixtures`. Only `custom_wasm.f3` was copied into `test/fixtures/`. The upstream `dump_rows` example wrote `custom_wasm_rows.json` with `trade_id` 1, 2, and 3.

## Host

`cargo check` of `native/f3_native` on `nightly-2025-11-15` compiled Wasmtime 28. The Vortex nightly was not changed. `F3_BUILD_NATIVE=1 MIX_ENV=test mix compile --force` produced the NIF.

Fuel is 5_000_000 instructions. Upstream sets none. Linear memory is 8 MiB. The built-in module grows a table to 3308 elements, so the table-element cap is 16_384. An omitted `wasm_id` is FlatBuffers default 0. This file omits it and has one module.

## Commands

```text
brew install wasi-libc wasi-runtimes
# wasi-libc 34, wasi-runtimes 23.1.5, llvm 23.1.5

cargo build --locked -p fff-ude-example-fff --target wasm32-wasip1 --profile opt-size-lvl3
# nightly-2025-02-24, WASI_SYSROOT set, rustc linker

f3_fixture_gen --upstream tmp/upstream-f3 --out /tmp/f3-stage3-fixtures
cargo run --release --example dump_rows -- /tmp/f3-stage3-rows /tmp/f3-stage3-fixtures/custom_wasm.f3

F3_BUILD_NATIVE=1 mix test --only native
6 passed

mix compile --force
mix ci
77 passed (3 doctests, 74 tests), 6 native tests excluded
coverage 92.30%
mix credo --strict found no issues
```

`mix test --only native` included the sandboxed read of `custom_wasm.f3`. Those rows match the manifest and `test/fixtures/golden/custom_wasm_rows.json`. The same run rejects a short buffer, fuel exhaustion, a 16 MiB memory minimum, a memory grow, `path_open`, `sock_accept`, a missing ABI symbol, and major 2. No throughput or RSS numbers were collected.

Default `F3.read/2` and `F3.stream/2` on `custom_wasm.f3` return `:unsupported_encoding` and do not pread the `WASMBinaries` section. `lib_urls` are not walked. A trace of `:httpc` during the sandboxed read received no calls.
