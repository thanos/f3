# Upstream compatibility

Inspection time: 2026-11-03T00:44:04Z. `main` was `bd92506447dc1333820cfe9a34ebbf497fe0219e` ("fix: format and some lints issues (#1)", committer date 2025-11-03T03:34:41Z). This build pins that full SHA. If upstream `main` moves, change the pin, regenerate fixtures, and update this file. Do not keep a stale SHA.

## Identity

| Item | Value |
| --- | --- |
| Repository | https://github.com/future-file-format/F3 |
| Commit | `bd92506447dc1333820cfe9a34ebbf497fe0219e` |
| License | MIT, copyright 2025 Xinyu Zeng and Ruijun Meng |
| Paper | Zeng et al., Proc. ACM Manag. Data 3(4), Article 245, SIGMOD 2025, https://doi.org/10.1145/3749163 |
| Upstream status | Research prototype. README: tested on Intel Debian 12, not for production. `format/File.fbs` says the definition is subject to change. |
| Wire version | `MAJOR_VERSION = 0`, `MINOR_VERSION = 1` in `fff-format/src/lib.rs` |
| This library | Elixir package `f3`, namespace `F3`. Not the `future-file-format` project. Hex package `f3` returned HTTP 404 on 2026-11-03. Not published. |

## Toolchain observed at the pin

`rust-toolchain.toml` selects `nightly-2025-02-24` and the extra targets `x86_64-unknown-linux-gnu` and `wasm32-wasip1`. It does not list `aarch64-apple-darwin`. On this machine rustup installed `nightly-2025-02-24-aarch64-apple-darwin` (rustc 1.87.0-nightly, 2025-02-23) because the host is Apple Silicon. Upstream does not claim that host.

`fff-poc/src/lib.rs` enables `#![feature(new_range_api)]` and installs mimalloc as a global allocator. That combination is a reason not to link `fff-poc` into the BEAM. The Elixir package's optional NIF uses stable Rust and does not depend on `fff-poc`.

Workspace crates.io pins used by the writer include Arrow and Parquet 53.0.0 and FlatBuffers 24.3.25. Vortex and Lance come from `https://github.com/XinyuZeng/vortex.git` revision `c0d89a66cbaa542bd9aa277cfdf52f2728c4b37a` and `https://github.com/XinyuZeng/lance.git` revision `ff922b192422d5a4da8f3384e0a019925f4f339f`. The only git submodule is `third_party/flatbuffers`, used to build `flatc`.

A freestanding Cargo package that path-depends on `fff-poc` resolves those version ranges to newer crates that do not compile on this nightly. Fixture generation therefore builds inside the upstream workspace and its `Cargo.lock`.

## Postscript

The postscript is not FlatBuffers. `fff-poc/src/writer.rs` `FileWriter::finish` writes it in little-endian order and ends with the magic. `POSTSCRIPT_SIZE` is 32.

| Offset | Width | Field |
| --- | --- | --- |
| 0 | u32 | metadata size |
| 4 | u32 | footer size |
| 8 | u8 | footer compression |
| 9 | u8 | checksum type |
| 10 | u64 | data checksum |
| 18 | u64 | schema checksum |
| 26 | u16 | major version |
| 28 | u16 | minor version |
| 30 | 2 bytes | `F3` |

`F3.Format` records these widths. It does not parse a file. Stage 1 owns decoding and bounds checks.

Footer compression in the writer is `CompressionType::Uncompressed` (0). The checksum byte written today is `ChecksumType::XxHash as u8`, which is 0. `ChecksumType::from(u8)` panics on any other byte. This library must not copy that panic. Unknown checksum types become a tagged error in a later stage.

## File body

`format/File.fbs` describes the layout, and the schema comment says it can change:

1. Row-group data. Each column has IOUnits, called `Chunk` in the schema. An IOUnit holds contiguous EncUnits.
2. Optional Wasm binaries, as metadata sections.
3. Row-group and column metadata, including IOUnit offsets and EncUnit encodings. This is out of band from the footer.
4. Footer FlatBuffers (`root_type Footer`): Arrow IPC schema, row-group counts and pointers, optional section pointers, encoding versions, shared dictionary table.
5. The 32-byte postscript.

`EncodingType` is `CASCADE = 0` (Vortex) and `CUSTOM_WASM = 255`. `CompressionType` is `Uncompressed = 0`, `Zstd = 1`, `Lz4 = 2`.

Default writer options in `fff-poc/src/options.rs`: 8 MiB IOUnit, 65536-row EncUnit, one row group (`row_group_size = u64::MAX`), uncompressed, no built-in Wasm, `EncoderDictionary`. `set_row_group_size`, `set_compression_type`, `set_dictionary_type`, and `write_built_in_wasm` exist. Custom Wasm options cannot be combined with built-in Wasm. `write_built_in_wasm` reads `target/wasm32-wasip1/opt-size-lvl3/fff_ude_example_fff.wasm` at runtime (`BUILTIN_WASM_PATH` in `fff-test-util`).

Column metadata is not inline in the footer. A reader that decodes only the footer does not have every IOUnit.

## What this library claims

Stage 0 claims the constants, the source lifecycle, and the fixtures produced by that writer. It does not claim that it can decode them. The feature matrix lists each capability.

## Risk register

1. The FlatBuffers schema is explicitly unstable. A future upstream commit can invalidate fixtures and the version policy.
2. `fff-poc` needs nightly Rust and a global allocator. Linking it into a NIF can abort the BEAM. Stage 2 must isolate decoding behind a narrow API on stable Rust, or keep nightly in a separate process. This stage does neither.
3. Vortex and Lance are personal git forks, not crates.io releases. They can disappear or move.
4. Upstream's stated test host is Intel Debian 12. Apple Silicon and Linux arm64 are untested by upstream. Fixture generation on this Apple Silicon machine is a local experiment, not an upstream support claim.
5. `ChecksumType::from` panics on an unknown byte. A later parser must return an error before that path exists.
6. Metadata length fields are attacker-controlled. Stage 0 does not allocate from them. Stage 1 must cap them before any read.
7. Embedded Wasm and `lib_urls` in the schema are not fetched and not executed. A later stage must keep that as the default.
8. The Hex name `f3` was free on the inspection date. Publish only after checking again, and only with an explicit experimental label.
9. The built-in Wasm fixture depends on a `wasm32-wasip1` build of `fff-ude-example-fff`. On this Apple Silicon machine that build failed in `zstd-sys` because clang could not find the Wasm C headers. The fixture is omitted. Absence is not a claim that Wasm works.
10. `fff-poc` samples encodings with `rand::thread_rng`. Regenerating fixtures is not always byte-identical. The manifest records one real run.
11. Parent `.tool-versions` asks for Erlang 29.0.4, which is not installed here. This repository pins Elixir 1.20.2 / OTP 28 so `mix` runs.
