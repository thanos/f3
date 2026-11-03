# Fixtures

These files were produced by upstream `fff_poc::writer::FileWriter` at the commit in [manifest.json](manifest.json). They are not hand-written byte strings. `mix test` checks each SHA-256, the size, and that the file ends with `F3`.

## Regenerate

From the repository root:

```shell
scripts/fixtures/generate.sh
```

The script clones `https://github.com/future-file-format/F3.git` at the pinned SHA into gitignored `tmp/upstream-f3`, builds `flatc` from the `third_party/flatbuffers` submodule, and compiles `scripts/fixtures/generator/src/main.rs` as a binary of the `fff-poc` package with `cargo build --locked` and Rust `nightly-2025-02-24`. A freestanding crate resolves newer dependencies than that nightly can compile, so the generator is not built from its own `Cargo.toml`. asdf shims are removed from `PATH` for that build.

You need git, cmake, a C compiler, and rustup. The script does not run in required CI.

The generator tries `small`, `nullable`, `wide`, `multi_row_group`, Zstd, Lz4, a dictionary column, a nested struct and list, and upstream's built-in Wasm path (`write_built_in_wasm`). A failure is recorded under `skipped` in the manifest and the partial file is deleted.

The 2026-11-03 run wrote eight files. `LocalDictionary` and the struct-plus-list file succeeded. `custom_wasm.f3` was skipped. The Wasm crate `fff-ude-example-fff` did not build: `clang` could not compile `zstd-sys` for `wasm32-wasip1` because the Wasm C headers were missing (`stdlib.h`, `string.h`, `stdio.h`, `assert.h`). An earlier attempt also reported `unknown target triple 'wasm32-unknown-wasip1'`. Upstream reads `target/wasm32-wasip1/opt-size-lvl3/fff_ude_example_fff.wasm` when `write_built_in_wasm` is set, so the generator did not invent a Wasm fixture. The `skipped` entry in `manifest.json` quotes those clang errors.

## Read a tail

```shell
mix run examples/tutorial_02.exs
```

That prints the postscript of `small.f3`. It uses `F3.Format.postscript_layout/0` and does not decode the footer.

## Provenance

`manifest.json` is the list of files, row values, writer options, SHA-256, and upstream SHA. Update the tutorial 2 hex dump from the script after a regeneration. Do not edit fixture bytes by hand.

The upstream encoder samples with `rand::thread_rng` in `fff-poc/src/encoder/physical.rs`. Repeated runs of the same binary are not always byte-identical. The checksums below are the bytes committed from one run. A later regeneration can change them.
