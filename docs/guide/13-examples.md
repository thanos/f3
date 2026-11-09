# Examples

These are the calls a caller actually makes. The native decoder is required where a step reads or writes rows. Metadata, options that fail early, and an Elixir extension run on every build.

The Livebook `docs/examples.livemd` runs the same cases from the repository root. Its cells stay on results that do not need the native decoder, so `mix test` can execute them.

## Inspect a file

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, text} = F3.inspect(file, detail: false, format: :text)
{:ok, file} = F3.close(file)
```

`text` includes `schema: trade_id int64, symbol utf8, price float64`. `mix f3.inspect test/fixtures/small.f3` prints the same summary.

## Project one column

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, [batch]} = F3.read(file, columns: ["symbol"])
{:ok, rows} = F3.Batch.to_rows(batch)
{:ok, file} = F3.close(file)
```

`rows` is `[%{"symbol" => ...}, ...]` when the native decoder is compiled. Without it, `F3.read/2` returns `:native_unavailable` and does not read the payload.

## Write a local file and read it back

```elixir
path = "tmp/trades.f3"

{:ok, writer} =
  F3.Writer.open(path,
    schema: [trade_id: :int64, symbol: :utf8],
    compression: :uncompressed
  )

:ok = F3.Writer.write(writer, [%{trade_id: 1, symbol: "aaa"}])
{:ok, _writer} = F3.Writer.close(writer)

{:ok, file} = F3.open(path)
{:ok, [batch]} = F3.read(file)
{:ok, [%{"trade_id" => 1, "symbol" => "aaa"}]} = F3.Batch.to_rows(batch)
{:ok, _file} = F3.close(file)
```

Without the native writer, `F3.Writer.open/2` with a valid schema returns `:not_implemented` and creates no file. A missing schema returns `:invalid_argument` on every build.

## An HTTP URL that is refused

```elixir
{:error, error} = F3.open("unused", source: {:http, "ftp://example.test/trades.f3"})
```

`error.message` is `"http url must be http or https"`. No request is sent. A partial set of signing keys fails the same way, before `HEAD`. Redirects from a real server are `:io` with reason `:redirect`.

## An Elixir decoder

Register the module, then pass the registry pid. The sample ignores the unit bytes and returns one `int64`. A file read still needs a file that names this encoding, and the native decoder for the rest of the file.

```elixir
defmodule Example.TradeCount do
  @behaviour F3.Extension

  @impl true
  def decode(_bytes, _metadata, :i64) do
    F3.Column.from_native(:i64, 1, <<9::little-64>>, nil)
  end

  def decode(_bytes, _metadata, _type) do
    {:error, F3.Error.unsupported_encoding(:decode, "only int64")}
  end
end

{:ok, registry} = F3.Registry.start_link(capacity: 1)

:ok =
  F3.Registry.register(
    registry,
    %{encoding: :custom_wasm, version: %{major: 1, minor: 0, patch: 0}},
    Example.TradeCount
  )
```

`examples/tutorial_01.exs` through `examples/tutorial_09.exs` are longer scripts. `mix test` runs them. They cover the file layout, a first read, streaming, writing, Wasm, Arrow and Parquet as jobs, and the recorded benchmark.
