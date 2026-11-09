# Decoders

A CASCADE encoding unit is decoded by the native library. That is the default path for the committed fixtures. You do not register anything for those files.

An F3 file can also name an encoding this library does not implement. You can supply an Elixir module for that encoding. The file does not name the module. You do.

```elixir
defmodule TradeCount do
  @behaviour F3.Extension

  @impl true
  def decode(_bytes, _metadata, :i64) do
    F3.Column.from_native(:i64, 1, <<9::little-64>>, nil)
  end

  def decode(_bytes, _metadata, _type) do
    {:error, F3.Error.unsupported_encoding(:decode, "only int64")}
  end
end

key = %{
  encoding: :custom_wasm,
  version: %{major: 1, minor: 0, patch: 0},
  compression: :uncompressed
}

{:ok, registry} = F3.Registry.start_link()
:ok = F3.Registry.register(registry, key, TradeCount)

{:ok, file} = F3.open("trades.f3")
{:ok, batches} = F3.read(file, extensions: registry)
```

`decode/3` receives the encoded bytes, a metadata map, and the physical type. The metadata map has `:encoding`, `:version` (`%{major, minor, patch}`), `:wasm_id`, and `:compression`. Return `{:ok, column}` or `{:error, %F3.Error{}}`. An extension error is returned to you. The reader does not fall through into Wasm.

`F3.Registry.start_link/1` takes `capacity:`, default 64, maximum 1024. Pass that pid as `extensions:`. Two reads share registrations only when you pass the same pid. A registration that sets `:wasm_id` matches only that id. A registration that omits it matches any id, after an exact id is tried.

The native CASCADE decoder still runs for a CASCADE unit whose version this build accepts. The extension path is the one you registered.
