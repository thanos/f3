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

`fff-poc/src/lib.rs` enables `#![feature(new_range_api)]` and installs mimalloc as a global allocator. That combination is a reason not to link `fff-poc` into the BEAM. `native/f3_native` does not depend on `fff-poc` and does not install a global allocator.

The CASCADE decoder does not build on stable Rust. A stable 1.97.1 `cargo check` stops in `fastlanes` on `#![feature(generic_const_exprs)]`. `nightly-2025-02-24` (rustc 1.87.0-nightly) cannot compile this crate either: Rustler 0.38.0 declares `rust-version = "1.91"`, and a fresh crates.io resolve pulls `croaring` 2.9.0 (`rust-version` 1.95) plus `icu_*`, `gimli`, and `backtrace` crates that want 1.88. A current nightly (rustc 1.101.0-nightly, 2026-10-15) still accepts Vortex's feature gates, then fails in `vortex-fastlanes` because [rust#149127](https://github.com/rust-lang/rust/pull/149127) (merged 2025-11-21) changed `ArrayChunks::into_remainder` from `Option<array::IntoIter>` to `array::IntoIter`.

`native/f3_native/rust-toolchain.toml` therefore pins `nightly-2025-11-15` (rustc 1.93.0-nightly, 2025-11-14). That nightly is after Rust 1.91 and before the `into_remainder` change. The crate also pins `chrono = "=0.4.39"` (0.4.45 adds `Datelike::quarter`, which collides with `arrow-arith` 53.3.0) and `croaring = "=2.1.0"` (the version in the upstream lock; 2.1.0 does not require Rust 1.95). On that toolchain the NIF decodes the first uncompressed int64 EncUnit of `small.f3` (offset 0, size 1664) to the values 1, 2, and 3. The loaded dylib is arm64 and exports neither `fff-poc` nor mimalloc.

Workspace crates.io pins used by the writer include Arrow and Parquet 53.0.0 and FlatBuffers 24.3.25. The upstream `Cargo.lock` resolves `arrow-array` to 53.3.0; crates.io does not offer `arrow-buffer` 53.0.0 (53.3.0 and 53.4.1 are the selectable releases). `f3_native` pins `arrow-array = "=53.3.0"`. Vortex and Lance come from `https://github.com/XinyuZeng/vortex.git` revision `c0d89a66cbaa542bd9aa277cfdf52f2728c4b37a` and `https://github.com/XinyuZeng/lance.git` revision `ff922b192422d5a4da8f3384e0a019925f4f339f`. The only git submodule is `third_party/flatbuffers`, used to build `flatc`.

A freestanding Cargo package that path-depends on `fff-poc` resolves those version ranges to newer crates that do not compile on this nightly. Fixture generation and the Stage 4 writer therefore build inside the upstream workspace and its `Cargo.lock`.

## Writer

`FileWriter` lives only in `fff-poc` (`fff-poc/src/writer.rs`). There is no `FileWriterV2` and no path API. The caller supplies `Write + Seek`. `try_new` writes nothing. `write_batch` encodes one Arrow `RecordBatch`. `finish` consumes the writer, flushes encoders, writes the footer, and only then writes the 32-byte postscript and the `F3` magic. A failed `finish` leaves whatever bytes were already flushed. The type does not rename or delete a path.

Default options from `FileWriterOptionsBuilder::with_defaults`: IOUnit 8 MiB, `encoding_unit_len` 65536, one row group (`row_group_size = u64::MAX`), checksum type xxHash, `write_built_in_wasm` false, `EncoderDictionary`, IOUnit checksums off, compression `Uncompressed`. `encoding_unit_len` is stored and not read. `custom_encunit_len` is marked unfinished. This library does not expose either. A batch can overshoot `row_group_size` because the check runs after the batch is encoded. Compression after Vortex is `Uncompressed`, `Lz4` (`lz4_flex`), or `Zstd`. The stored encoding is `CASCADE` at version `0.21.0`. `write_built_in_wasm` stays false. No custom Wasm options are set.

`create_logical_encoder` accepts the non-nested Arrow primitives, `List`/`LargeList`, and `Struct`. `Map` is `todo!`. This library's reader can round-trip signed int64 and int32, unsigned int64, int32, int16, and int8, float64, float32, bool, utf8, lists of those, and structs of those, including nulls. The writer claims that set only. It does not claim signed int8 or int16, float16, binary, decimal, dates, timestamps, map, an Arrow dictionary type, or a shared dictionary.

The helper is a separate process. `fff-poc` installs mimalloc as a global allocator and pulls `reqwest` through `object_store`, and Rustler 0.38 does not build on `nightly-2025-02-24`. `native/f3_write` is copied onto the pinned checkout and compiled as `fff-poc`'s `f3_write` bin with `cargo build --locked` on `nightly-2025-02-24`. There is no freestanding `Cargo.lock` in that directory: resolving one pulls crates this nightly cannot compile. `native/f3_native` does not depend on it. Elixir writes a temp file in the destination directory and renames it only after `finish` succeeds. That rename is local-filesystem behavior, not a remote write.

A zero-row batch is not sent. An empty `write_batch` at this pin leaves a chunk this library cannot concatenate. `finish` always closes the current row group, so a batch that already crossed `row_group_size` is followed by an empty group unless a later batch is still open. A list column split across two `write_batch` calls makes pinned `FileReaderV2` panic in `primitive_to_arrow` because the child `ScalarBuffer` is not aligned. This library concatenates the offset column and reads that file. The independent row check uses one batch for nested values.

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

## Wasm ABI at this pin

Recorded from `fff-ude/src/ffi.rs`, `fff-ude-wasm/src/lib.rs`, `fff-poc/src/decoder/encunit.rs`, and `fff-poc/src/file/footer.rs` at `bd92506447dc1333820cfe9a34ebbf497fe0219e`. This is not a claim that a Wasm fixture has been produced.

The version symbol is the exported name `FFFUDE_VERSION_1_0`. Upstream `fff-ude-wasm` accepts a major less than or equal to 3. This library accepts major 1 only, because that is the version the built-in example exports. Majors 2 and 3 stay unsupported until a fixture uses them.

The host crate is Wasmtime 28.0.0, the workspace pin. The encunit call is `decode_general_ffi` (`WASM_FUNC_GENERAL`). It returns an iterator of Arrow buffers. Non-nested types are rebuilt from those buffers. Nested Wasm output is `unimplemented!` upstream, so this library does not claim it. Required exports are `alloc`, `dealloc`, `buffer_iterator_next`, `buffer_iterator_drop`, `buffer_drop`, and `memory`. `init_ffi` and `decode_ffi` are optional and unused. `fff-ude-wasm` is not a dependency. It installs a process-global engine and is tied to `fff-poc`.

WASI is linked. The context built for an instance has size-capped stdout and stderr only. There is no preopened directory, no network, and the process environment is not inherited. A module that imports `path_open` or a socket is refused before instantiation. `StoreLimits` caps linear memory at 8 MiB. A module is refused above 16 MiB. The pinned `fff-ude-example-fff` artifact is 10_661_135 bytes, so the ceiling is above the 8 MiB figure that would have rejected this fixture. An omitted `wasm_id` is FlatBuffers default 0. Upstream sets no fuel and no wall-clock limit. This library adds a fuel budget of 5_000_000 instructions because Wasmtime 28 supports `consume_fuel`. Exhaustion is `:resource_limit`. That cap is ours.

Wasm bytes live in the `WASMBinaries` section. `wasm_id` is the index into that vector. Upstream compiles every module in the section on first use. This library compiles one module, only after `wasm: :sandbox` (or a registered extension has already declined the unit), and only the id the encunit names. A compiled module may be cached by the SHA-256 of its bytes. The cache is bounded to 8 modules and 8 MiB, and clearing it drops every entry. A cache hit still requires that read to have opted in. Metadata inspection does not compile or execute anything.

`DEFAULT_ENCODING_VERSIONS` lists CASCADE `0.21.0` and CUSTOM_WASM `1.0.0`. `create_encunit_decoder` uses Wasm for CASCADE only when the file version is newer and the reader major is 0 or the majors differ. Native `0.21.0` has major 0, so a newer CASCADE version takes Wasm and an equal or older version stays on the Vortex NIF. The eight committed fixtures stay on that NIF. `lib_urls` stay inert strings. An opt-in HTTP range source does not request them and does not follow redirects. The `wasmtime` 28.0.0 and `wasi-common` 28.0.0 manifests set `license = "Apache-2.0 WITH LLVM-exception"`.

## What this library claims

Stage 0 claims the constants, the source lifecycle, and the fixtures produced by that writer. It does not claim that it can decode them. The feature matrix lists each capability.

## Risk register

1. The FlatBuffers schema is explicitly unstable. A future upstream commit can invalidate fixtures and the version policy.
2. `fff-poc` needs nightly Rust and a global allocator. The Stage 2 NIF does not link it. Vortex still needs nightly, so `f3_native` pins `nightly-2025-11-15` rather than stable or `nightly-2025-02-24`. See the toolchain section.
3. Vortex and Lance are personal git forks, not crates.io releases. They can disappear or move.
4. Upstream's stated test host is Intel Debian 12. Apple Silicon and Linux arm64 are untested by upstream. Fixture generation on this Apple Silicon machine is a local experiment, not an upstream support claim.
5. `ChecksumType::from` panics on an unknown byte. A later parser must return an error before that path exists.
6. Metadata length fields are attacker-controlled. Stage 0 does not allocate from them. Stage 1 must cap them before any read.
7. Embedded Wasm and `lib_urls` stay unfetched by default. Wasm runs only for `wasm: :sandbox`. An opt-in HTTP source does not follow redirects and does not request `lib_urls`.
8. The Hex name `f3` was free on the inspection date. Publish only after checking again, and only with an explicit experimental label.
9. `custom_wasm.f3` was produced on this Apple Silicon machine after `brew install wasi-libc` (34) and `wasi-runtimes` (23.1.5). Homebrew LLVM 23.1.5 compiled the C objects in `zstd-sys`. The final Wasm link used the `nightly-2025-02-24` rustc linker, not Homebrew clang. The fixture is one local writer run. It is not an upstream support claim for Apple Silicon.
10. `fff-poc` samples encodings with `rand::thread_rng`. Regenerating fixtures is not always byte-identical. The manifest records one real run.
11. Parent `.tool-versions` asks for Erlang 29.0.4, which is not installed here. This repository pins Elixir 1.20.2 / OTP 28 so `mix` runs.
