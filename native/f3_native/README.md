# f3_native

Optional Rustler crate for the Elixir `f3` package.

`nif_info/0` returns the crate name and version. `decode_encunit/3` decodes one CASCADE encoding unit on the dirty CPU scheduler and returns an owned Elixir term. It does not open files, decode FlatBuffers, or run WebAssembly.

The crate depends on Vortex git revision `c0d89a66cbaa542bd9aa277cfdf52f2728c4b37a` and `arrow-array` 53.3.0. It does not depend on `fff-poc` and it does not install a global allocator. `rust-toolchain.toml` pins `nightly-2025-11-15`. Stable Rust cannot compile Vortex. `nightly-2025-02-24` cannot compile Rustler 0.38. See `docs/upstream-compatibility.md`.

`mix compile` skips it unless `F3_BUILD_NATIVE=1`.
