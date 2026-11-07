# Stage 4 test report

Recorded 2026-11-06 after the commands below. GitHub Actions has not been run from this machine. Linux x86_64 is configured and is untested here. No latency or RSS numbers.

## Environment

| Tool | Version |
| --- | --- |
| Host | Darwin arm64 |
| Elixir | 1.20.2, compiled with Erlang/OTP 28 |
| OTP | 28, erts 16.2 |
| Decoder Rust | 1.93.0-nightly (`nightly-2025-11-15`, commit b6d7ff3aa, 2025-11-14), aarch64-apple-darwin |
| Writer Rust | 1.87.0-nightly (`nightly-2025-02-24`, commit f8a913b13, 2025-02-23), aarch64-apple-darwin |
| Upstream | `bd92506447dc1333820cfe9a34ebbf497fe0219e` |

The eight committed `.f3` fixtures and `custom_wasm.f3` were not regenerated. `f3_write` is a Mach-O arm64 executable copied to gitignored `priv/native/f3_write`. `f3_native` does not link it. There is no freestanding `native/f3_write/Cargo.lock`. Resolving one pulls crates this nightly cannot compile. The binary is `cargo build --locked -p fff-poc --bin f3_write` inside `tmp/upstream-f3`.

`nightly-2025-02-24` compiled `fff-poc` here. The helper was not reimplemented. A list column split across two batches makes pinned `FileReaderV2` panic in `primitive_to_arrow` (unaligned `ScalarBuffer`). This library reads that file. The upstream row check uses one batch for nested values. An empty batch is accepted and is not sent.

## Commands

`cargo build --locked --release -p fff-poc --bin f3_write` from `tmp/upstream-f3`, with `nightly-2025-02-24` on `PATH`, finished in 8.34s.

`F3_BUILD_NATIVE=1 mix test --only native` — 15 passed, 83 excluded.

`F3_BUILD_NATIVE=1 mix run examples/tutorial_05.exs` printed:

```text
command: mix run examples/tutorial_05.exs
write: round trip
[%{"price" => nil, "symbol" => "AAPL", "trade_id" => 1}]
```

`unset F3_BUILD_NATIVE && mix ci` — format check, compile with warnings as errors, Credo strict, and docs passed. Tests: 83 passed (3 doctests, 80 tests), 15 excluded. Coverage 90.03%. The beam was the rust-free stub.
