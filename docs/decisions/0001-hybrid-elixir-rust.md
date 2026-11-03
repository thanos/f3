# ADR 0001: Elixir owns the API, Rust stays optional

## Status

Accepted for Stage 0. Revisit when Stage 1 differential tests fail, or when Stage 2 must keep Arrow buffers alive across the NIF boundary.

## Context

F3 files end with a 32-byte postscript that is ordinary little-endian fields plus the magic `F3`. The footer and column metadata are FlatBuffers. The payload is Vortex (`CASCADE`) or an embedded Wasm decoder (`CUSTOM_WASM`). Upstream `fff-poc` is a nightly-Rust research crate with a process-global mimalloc allocator, and its Vortex and Lance dependencies are git forks.

Elixir callers need `{:ok, value}` and `{:error, %F3.Error{}}`, explicit close, and a library that loads without a native toolchain. The postscript has to stay readable when the NIF is absent.

## Options

1. Call `fff-poc` directly from Rustler. Rejected. The crate needs nightly Rust and a global allocator, and its public writer and reader types are experimental.
2. Decode FlatBuffers only in Rust, using the `flatbuffers` 24.3.25 crate and the generated schema. Possible later, as a small crate that does not link Vortex. It is not required to open a file or to read the postscript.
3. Decode the postscript, and then the footer tables Stage 1 needs, in Elixir. The postscript is fixed-width. FlatBuffers is a documented binary layout, and the Elixir walker can be checked against the pinned schema and the upstream reader. A Rust FlatBuffers bridge remains the fallback if those differential tests fail.

## Decision

Elixir owns the public API, errors, source lifecycle, version policy, and the postscript. Stage 1 will decode the FlatBuffers footer with a bounded pure-Elixir walker checked against pinned `File.fbs` and the upstream reader. A small stable-Rust `flatbuffers` 24.3.25 bridge is the fallback only if those tests fail. `f3_native` in this stage is a version probe behind `F3_BUILD_NATIVE=1`. It does not decode.

Do not compile `fff-poc`, Vortex, or Wasmtime into `f3_native` for metadata.

## Consequences

- `mix test` runs without Rust.
- Postscript inspection cannot be broken by a NIF load failure.
- Stage 1 has to be careful with vtable bounds. The fallback is a small Rust parser, not a fork of `fff-poc`.
- Stage 2 still needs a native decoder for Vortex and Wasm. That work starts from a new, narrow API, not from today's scaffold.
- Wasm stays off. The scaffold has no interpreter.

## Revisit when

- Stage 1 cannot match the upstream reader's metadata on the committed fixtures.
- A NIF must own Arrow buffers, dirty schedulers, or cancellation.
- Upstream publishes a stable crate that builds on stable Rust without a global allocator.
