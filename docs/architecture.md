# Architecture

The library owns the byte-source lifecycle, the postscript, the footer, and the public read API. Rust decodes one CASCADE encoding unit at a time and returns owned Elixir terms. Arrow buffers do not cross the NIF. Wasm is not executed.

```mermaid
flowchart LR
  Read[F3.read or F3.stream]
  Meta[F3.Footer]
  Slice[pread one EncUnit]
  Nif[dirty CPU NIF]
  Batch[F3.Batch]
  Read --> Meta --> Slice --> Nif --> Batch
```

## Components

`F3` is the public module. `open/2` builds an `F3.File` around either `F3.IO.Local` or `F3.IO.Memory`. `close/1` returns the updated handle and is idempotent on that handle. `schema/1`, `metadata/1`, and `inspect/2` decode the tail when the handle is open. `read/2` returns columnar batches. `stream/2` returns a stream and does not pread until the first pull.

`F3.Format` holds the pinned magic, the 32-byte postscript layout, and `compatible?/2`. The only accepted wire version is 0.1. `F3.Postscript` reads that layout, rejects a short tail, a bad magic, any other version, a compressed footer, and a claimed size past the file or past `max_metadata_bytes:`. The default cap is 16 MiB and is an argument, not a process global.

`F3.FlatBuffer` walks one buffer: root offset, vtable, scalars, strings, vectors, and unions. Offsets are checked against the buffer length. Depth and the number of visited tables are capped. `F3.Footer` turns the footer and the out-of-band column-metadata roots into `F3.Schema`, `F3.Metadata`, and `F3.RowGroup`. Arrow types the fixtures do not use become `{:unsupported, id}` and do not fail the file. Wasm section offsets are recorded and the bytes are not read. Checksums are recorded and not verified.

`F3.Batch` stores columns keyed by logical field name. `to_rows/1` zips them into maps and is the convenience path. `F3.Writer` returns `:not_implemented` and creates no file.

`F3.Reader` selects columns and row groups, checks a chunk checksum when the footer stored one, and slices a decoded unit to `batch_size` (default 8192). `F3.Logical` stitches unnamed physical columns into the logical tree. `F3.Native` is compiled only when `F3_BUILD_NATIVE=1`. `decode_encunit/3` runs on the dirty CPU scheduler. The crate calls Vortex and Arrow. It does not link `fff-poc`, it does not install a global allocator, and it does not run Wasm. Without the NIF, `read/2` and `stream/2` return `:native_unavailable`. Metadata inspection still works.

There is no `Application` callback, no supervision tree, and no process registry. See [decisions/0001-hybrid-elixir-rust.md](decisions/0001-hybrid-elixir-rust.md).

## What Stage 3 must keep off

Wasm execution. A `CUSTOM_WASM` unit is `:unsupported_encoding`. The bytes are not read and not run. A shared dictionary is the same refusal. A local dictionary is gathered in Elixir after the NIF returns the values and the indexes.

## Fixture path

`scripts/fixtures/generate.sh` clones the pinned commit into gitignored `tmp/upstream-f3`, copies `scripts/fixtures/generator/src/main.rs` to `fff-poc/src/bin/f3_fixture_gen.rs` in that checkout, and builds it with `cargo build --locked`. `scripts/fixtures/dump_metadata.sh` runs the pinned reader once and writes `test/fixtures/golden/*.json`. `mix test` checks the manifest and those JSON files. It does not compile upstream.
