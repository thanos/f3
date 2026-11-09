# F3 for Elixir

Experimental library, version 0.1.0, for the [F3](https://github.com/future-file-format/F3) columnar file format. Upstream F3 is a research prototype. This package reads the postscript, the footer, and, when the native decoder is compiled, CASCADE row data. `CUSTOM_WASM` runs only when a read passes `wasm: :sandbox`. A local writer is available in that same native build.

The pinned upstream commit is `bd92506447dc1333820cfe9a34ebbf497fe0219e`. The only wire version this build accepts is major 0, minor 1. See [docs/upstream-compatibility.md](docs/upstream-compatibility.md).

## What works

`F3.open/2` and `F3.close/1` acquire and release a local file, an in-memory binary, or an opt-in HTTP range source. `F3.schema/1`, `F3.metadata/1`, and `F3.inspect/2` decode the footer. `F3.read/2` and `F3.stream/2` decode CASCADE units when the native decoder is loaded, and return `:native_unavailable` when it is not. `F3.Writer.open/2` writes a local file in that build. Without it, a valid open returns `:not_implemented` and creates no file. There is no application callback to start.

The block below is the native build. On the default build, `F3.read/2` returns `:native_unavailable` and the schema and inspect calls still succeed.

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, schema} = F3.schema(file)
{:ok, text} = F3.inspect(file)
{:ok, [batch]} = F3.read(file)
{:ok, rows} = F3.Batch.to_rows(batch)
{:ok, file} = F3.close(file)
```

`mix f3.inspect test/fixtures/small.f3` prints the same summary. Checksums are shown and not verified. A Wasm section is a pointer until a read passes `wasm: :sandbox`. Inspection does not execute it.

A memory source does not touch the path. An HTTP source does not open `path` either. Redirects are refused, and footer `lib_urls` are not fetched.

```elixir
{:ok, file} = F3.open("unused", source: {:memory, binary})
{:ok, file} = F3.open("unused", source: {:http, url})
```

## Build

Elixir 1.20.2 and OTP 28. The default `mix test` does not compile Rust.

```shell
mix deps.get
mix test
mix ci
```

`mix ci` is the required CI job: format, compile with warnings as errors, Credo, tests with coverage, and docs. It stops at the first failing step. The test step stops at the first failed test and requires 90% line coverage.

Source builds only. There is no precompiled NIF. Hex has not been published.

```shell
F3_BUILD_NATIVE=1 mix compile
F3_BUILD_NATIVE=1 mix test --only native
```

The NIF build calls rustup's `nightly-2025-11-15` binaries even when asdf or Homebrew puts a stable `cargo` earlier on `PATH`. The writer is a separate `f3_write` binary. That build fetches pinned `fff-poc` and compiles it with `nightly-2025-02-24`. The NIF decodes one CASCADE encoding unit on the dirty CPU scheduler and, only when Elixir asks, one Wasm module with Wasmtime 28. It does not link `fff-poc` and it does not install a global allocator. Mix recompiles `F3.Native` when the flag changes. The default `mix test` excludes the native tests and does not invoke `cargo`.

`scripts/bench.exs` times `F3.read/2` and `F3.stream/2` on the committed fixtures. It does not download data and it is not a CI gate. `mix test` excludes the `:minio` tag unless `F3_MINIO=1`.

Regenerate fixtures with `scripts/fixtures/generate.sh`. That script clones the pinned upstream commit, builds `fff-poc` with Rust `nightly-2025-02-24`, and rewrites `test/fixtures/`. It is not part of `mix test`.

## Status

| Area | Status |
| --- | --- |
| Open and close a byte source | implemented |
| HTTP range read | implemented, opt-in, no redirects |
| Postscript, schema, and footer metadata | implemented |
| Read rows, project, stream | implemented when `F3_BUILD_NATIVE=1` |
| Write a local file | implemented when `F3_BUILD_NATIVE=1` |
| Embedded Wasm execution | opt-in with `wasm: :sandbox` |

The package name `f3` returned 404 from the Hex API on 2026-11-03. Nothing has been published. Re-check Hex before any release.

Tutorials: [docs/tutorials/README.md](docs/tutorials/README.md). API examples: [docs/examples.livemd](docs/examples.livemd).

## Roadmap

Library version `0.1.0`. The only accepted wire version is major 0, minor 1. Hex has not been published.

This version includes:

- opening a local file, an in-memory binary, or an opt-in HTTP range source
- postscript and footer inspection, including schema and checksums
- row reads and streams through the Vortex NIF, with column and row-group selection
- a local writer for the types in the status table, in a separate process
- opt-in Wasm for `CUSTOM_WASM`

Still outside this version:

- a Hex release, and precompiled NIFs
- shared dictionaries
- signed `int8` and `int16`, `float16`, plain binary, decimal, dates, timestamps, maps, and Arrow dictionary columns
- writes to a remote URL, and fetches of footer `lib_urls`
- a required MinIO job, or a benchmark gate in CI
- Linux arm64 and upstream's Intel Debian 12 image, which have not been run here

Wasm generation stays off. The writer does not gain a remote path in this version.
