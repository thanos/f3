# F3 for Elixir

[![CI](https://github.com/thanos/f3/actions/workflows/ci.yml/badge.svg)](https://github.com/thanos/f3/actions/workflows/ci.yml)
[![Hex.pm](https://img.shields.io/hexpm/v/f3.svg)](https://hex.pm/packages/f3)
[![Hexdocs](https://img.shields.io/badge/hex-docs-7e57c2.svg)](https://hexdocs.pm/f3)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](https://opensource.org/licenses/MIT)

F3 is a columnar research file format. This library, version 0.1.0, opens an F3 file from Elixir, prints the schema and footer, and reads or writes rows when the native decoder is loaded.

The only wire version this library accepts is major 0, minor 1. Hex has not published the package. Add this repository as a path dependency until a release exists. A published package downloads precompiled NIFs for macOS Apple silicon and Linux x86_64. In this checkout, compile them with `F3_BUILD_NATIVE=1`.

## Quick start

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, schema} = F3.schema(file)
{:ok, text} = F3.inspect(file)
{:ok, file} = F3.close(file)
```

`small.f3` has three rows. The fields are `trade_id` (`int64`), `symbol` (`utf8`), and `price` (`float64`). `F3.inspect/2` prints that summary and does not read the row payload.

Reading the rows needs the native decoder:

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, [batch]} = F3.read(file)
{:ok, rows} = F3.Batch.to_rows(batch)
{:ok, file} = F3.close(file)
```

Without that decoder, `F3.read/2` returns `{:error, %F3.Error{category: :native_unavailable}}`. Schema and inspect still succeed. `mix f3.inspect test/fixtures/small.f3` prints the same summary.

A memory source and an HTTP source do not open `path`. HTTP is opt-in and does not follow redirects.

```elixir
{:ok, file} = F3.open("unused", source: {:memory, binary})
{:ok, file} = F3.open("unused", source: {:http, url})
```

## Guide

Start with [Introduction](docs/guide/01-introduction.md) and [Quick start](docs/guide/02-quick-start.md). [Configuration](docs/guide/03-configuration.md) is the option list. Reading, writing, streaming, decoders, and Wasm follow. [Status and roadmap](docs/guide/11-status-and-roadmap.md) says what 0.1.0 includes.

Runnable examples are in [docs/examples.livemd](docs/examples.livemd). Building the native decoder is in [docs/contributing.md](docs/contributing.md).
