# Writing F3 from Elixir

**Status:** technically reviewed  
**Audience:** an Elixir engineer who can run `mix` in this repository.  
**Estimated reading time:** 8 minutes, estimated from length, not from a timed reading.  
**Upstream pin:** `bd92506447dc1333820cfe9a34ebbf497fe0219e`

This article writes one local F3 file and reads it back. The writer is an out-of-process helper compiled only when `F3_BUILD_NATIVE=1`. The default `mix test` build does not start it. A valid `open/2` then returns `:not_implemented` and creates no file.

## Setup

The project pins Elixir 1.20.2 on OTP 28. `mix test` does not need Rust. The native build uses two nightlies: `nightly-2025-11-15` for the CASCADE decoder, and `nightly-2025-02-24` for the writer helper. The helper is pinned `fff-poc`. The decoder crate does not link that crate.

```shell
mix deps.get
mix test
```

## Open, write, close

`schema:` is a keyword list or an `%F3.Schema{}`. A bare `:int64` is non-null. `{:float64, null: true}` is nullable. `compression:` is `:uncompressed` by default, or `:zstd`, or `:lz4`.

```elixir
schema = [trade_id: :int64, symbol: :utf8, price: {:float64, null: true}]
{:ok, writer} = F3.Writer.open(path, schema: schema, compression: :zstd)
:ok = F3.Writer.write(writer, [%{trade_id: 1, symbol: "AAPL", price: nil}])
{:ok, writer} = F3.Writer.close(writer)
```

`open/2` creates a temp file in the destination directory and does not create or truncate the destination. `close/1` finishes the helper, then `File.rename/2` moves the temp file onto the destination. A failed finish deletes the temp file and leaves an existing destination unchanged. The rename is the local filesystem's rename. It is not a remote write. A second `close/1` returns the same closed handle.

`write/2` also accepts an `%F3.Batch{}`. A list of maps is the convenience form. A missing key is null only when the field is nullable. An extra key or a binary that is not UTF-8 is `:invalid_argument`. An integer outside the field width is `:invalid_type`. An empty batch is accepted and is not sent to the helper.

`examples/tutorial_05.exs` takes that path when the helper is loaded:

```text
command: mix run examples/tutorial_05.exs
write: round trip
[%{"price" => nil, "symbol" => "AAPL", "trade_id" => 1}]
```

That block is `F3_BUILD_NATIVE=1 mix run examples/tutorial_05.exs` on this machine. The default build prints `write: native writer is not loaded` and does not create a file.

```mermaid
flowchart LR
  Open[F3.Writer.open]
  Port[Port to f3_write]
  Tmp[temp file]
  Rename[rename after finish]
  Open --> Port --> Tmp --> Rename
```

`F3.Writer.open` checks the schema, starts the helper, and leaves the destination untouched. The helper encodes one batch at a time. The rename happens only after `finish` returns.

## What is experimental?

Upstream F3 at `bd92506447dc1333820cfe9a34ebbf497fe0219e` is a research prototype. The claimed writer types are the ones this reader already returns: signed int64 and int32, unsigned int64, int32, int16, and int8, float64, float32, bool, utf8, and lists and structs of those, including nulls. Signed int8 and int16, float16, binary, decimal, dates, timestamps, map, and shared dictionaries are not claimed. The writer does not embed Wasm. `iounit_bytes:` defaults to 8 MiB and is rejected above 64 MiB.

## Next

Tutorial 6 is Wasm. It stays off unless the caller passes `wasm: :sandbox`.

## Sources

- Public calls: `F3.Writer.open/2`, `F3.Writer.write/2`, `F3.Writer.close/1`
- Example: `examples/tutorial_05.exs`
- Helper: `native/f3_write`
- Upstream writer: `fff-poc/src/writer.rs` at the pinned commit
