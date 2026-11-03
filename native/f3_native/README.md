# f3_native

Optional Rustler crate for the Elixir `f3` package. It exports `nif_info/0`,
which returns the crate name and version.

This crate is stable Rust. It does not depend on upstream `fff-poc`, Vortex,
Arrow, or Wasmtime, and it does not decode F3 files.

`mix compile` skips it unless `F3_BUILD_NATIVE=1`.
