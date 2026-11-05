# F3 for Elixir

Experimental library for the [F3](https://github.com/future-file-format/F3) columnar file format. Upstream F3 is a research prototype. This package reads the postscript, the footer, and, when the native decoder is compiled, CASCADE row data. `CUSTOM_WASM` runs only when a read passes `wasm: :sandbox`. It does not write files.

The pinned upstream commit is `bd92506447dc1333820cfe9a34ebbf497fe0219e`. The only wire version this build accepts is major 0, minor 1. See [docs/upstream-compatibility.md](docs/upstream-compatibility.md).

## What works

`F3.open/2` and `F3.close/1` acquire and release a local file or an in-memory binary. `F3.schema/1`, `F3.metadata/1`, and `F3.inspect/2` decode the footer. `F3.read/2` and `F3.stream/2` decode CASCADE units when the native decoder is loaded, and return `:native_unavailable` when it is not. `F3.Writer` returns `:not_implemented`. There is no application callback to start.

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, schema} = F3.schema(file)
{:ok, text} = F3.inspect(file)
{:ok, [batch]} = F3.read(file)
{:ok, rows} = F3.Batch.to_rows(batch)
{:ok, file} = F3.close(file)
```

`mix f3.inspect test/fixtures/small.f3` prints the same summary. Checksums are shown and not verified. A Wasm section is a pointer until a read passes `wasm: :sandbox`. Inspection does not execute it.

A memory source does not touch the path:

```elixir
{:ok, file} = F3.open("unused", source: {:memory, binary})
```

## Build

Elixir 1.20.2 and OTP 28. The default `mix test` does not compile Rust.

```shell
mix deps.get
mix test
mix ci
```

`mix ci` is the required CI job: format, compile with warnings as errors, Credo, tests with coverage, and docs. It stops at the first failing step. The test step stops at the first failed test and requires 90% line coverage.

Set `F3_BUILD_NATIVE=1` before `mix compile` to build `native/f3_native`. That crate needs Rust `nightly-2025-11-15`. It decodes one CASCADE encoding unit on the dirty CPU scheduler and, only when Elixir asks, one Wasm module with Wasmtime 28. It does not link `fff-poc` and it does not install a global allocator. Mix reads the flag while compiling `F3.Native`; change it with `mix compile --force`. `mix test --only native` is the conformance suite. The default `mix test` excludes it.

Regenerate fixtures with `scripts/fixtures/generate.sh`. That script clones the pinned upstream commit, builds `fff-poc` with Rust `nightly-2025-02-24`, and rewrites `test/fixtures/`. It is not part of `mix test`.

## Status

| Area | Status |
| --- | --- |
| Open and close a byte source | implemented |
| Postscript, schema, and footer metadata | implemented |
| Read rows, project, stream | implemented when `F3_BUILD_NATIVE=1` |
| Write files | not implemented |
| Embedded Wasm execution | refused, and it does not run |

The package name `f3` returned 404 from the Hex API on 2026-11-03. Nothing has been published. Re-check Hex before any release.

Tutorials: [docs/tutorials/README.md](docs/tutorials/README.md).
