# ADR 0001: Elixir owns the API, Rust stays optional

## Status

Accepted. Stage 1 decoded the footer in Elixir. The eight committed fixtures match the upstream reader's metadata JSON, so the Rust FlatBuffers bridge was not added. Stage 2 decodes one CASCADE EncUnit in Rust and returns owned Elixir terms. Arrow buffers do not cross the NIF.

## Context

F3 files end with a 32-byte postscript that is ordinary little-endian fields plus the magic `F3`. The footer and column metadata are FlatBuffers. The payload is Vortex (`CASCADE`) or an embedded Wasm decoder (`CUSTOM_WASM`). Upstream `fff-poc` is a nightly-Rust research crate with a process-global mimalloc allocator, and its Vortex and Lance dependencies are git forks.

Elixir callers need `{:ok, value}` and `{:error, %F3.Error{}}`, explicit close, and a library that loads without a native toolchain. The postscript has to stay readable when the NIF is absent.

## Options

1. Call `fff-poc` directly from Rustler. Rejected. The crate needs nightly Rust and a global allocator, and its public writer and reader types are experimental.
2. Decode FlatBuffers only in Rust, using the `flatbuffers` 24.3.25 crate and the generated schema. Possible later, as a small crate that does not link Vortex. It is not required to open a file or to read the postscript.
3. Decode the postscript, and then the footer tables Stage 1 needs, in Elixir. The postscript is fixed-width. FlatBuffers is a documented binary layout, and the Elixir walker can be checked against the pinned schema and the upstream reader. A Rust FlatBuffers bridge remains the fallback if those differential tests fail.

## Decision

Elixir owns the public API, errors, source lifecycle, version policy, the postscript, and the footer. Stage 1 decodes the FlatBuffers footer with a bounded pure-Elixir walker checked against pinned `File.fbs` and the upstream reader. A small stable-Rust `flatbuffers` 24.3.25 bridge is the fallback only if those tests fail. It was not needed.

Stage 2 adds `decode_encunit/3` behind `F3_BUILD_NATIVE=1`. The crate depends on Vortex at `c0d89a66cbaa542bd9aa277cfdf52f2728c4b37a` and `arrow-array` 53.3.0. It does not depend on `fff-poc` and it does not install mimalloc. The function is scheduled `DirtyCpu`. Stable Rust cannot compile Vortex, and `nightly-2025-02-24` cannot compile Rustler 0.38, so this crate pins `nightly-2025-11-15`. See [../upstream-compatibility.md](../upstream-compatibility.md).

Do not compile `fff-poc` into `f3_native`. Stage 3 compiles Wasmtime 28.0.0 into the same crate. It does not depend on `fff-ude-wasm`. The host runs only after Elixir has selected `:wasm`.

Stage 4 writes through an out-of-process helper, `f3_write`, compiled as a bin of pinned `fff-poc` on `nightly-2025-02-24`. The helper's process has the mimalloc global allocator. The BEAM does not. `f3_native` still does not link `fff-poc`.

## Consequences

- `mix test` runs without Rust.
- Postscript inspection cannot be broken by a NIF load failure.
- Stage 1 walks vtables in Elixir with a depth cap and a visit cap. The fallback remains a small Rust parser, not a fork of `fff-poc`. It was not needed for the committed fixtures.
- Stage 2 decodes CASCADE units through that narrow NIF. Elixir projects, stitches nested columns, gathers a local dictionary, and slices batches.
- Wasm is opt-in. `wasm: :off` refuses `CUSTOM_WASM` without reading the section. `wasm: :sandbox` calls `decode_general_ffi` under fuel, memory, and module-size caps. Elixir extensions are registry policy, not a file field.

## Revisit when

- Stage 1 cannot match the upstream reader's metadata on the committed fixtures.
- A NIF must keep Arrow buffers alive, or cancellation has to cross the scheduler.
- Upstream publishes a stable crate that builds on stable Rust without a global allocator.
