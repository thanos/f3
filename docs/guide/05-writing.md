# Writing

`F3.Writer` writes one local file. It checks the schema in Elixir, sends batches to an out-of-process helper, and renames a temp file onto the destination when you close the writer. The rename is local-filesystem behavior. There is no remote write.

The helper is present only after the native build in [Configuration](03-configuration.md). Without it, a valid `open/2` returns `:not_implemented` and creates no file.

```elixir
{:ok, writer} =
  F3.Writer.open("trades.f3",
    schema: [trade_id: :int64, symbol: :utf8, price: {:float64, null: true}],
    compression: :zstd,
    checksum: true
  )

:ok =
  F3.Writer.write(writer, [
    %{"trade_id" => 1, "symbol" => "aaa", "price" => 10.5},
    %{trade_id: 2, symbol: "bbb", price: nil}
  ])

{:ok, writer} = F3.Writer.close(writer)
```

`schema:` is required. A bare `:int64` is non-null. `{:float64, null: true}` is nullable. Row maps may use atom or string keys. A missing key is null only when the field is nullable. An integer outside the field width is `:invalid_type`. A binary that is not UTF-8 is `:invalid_argument`. An empty batch is accepted and does not call the helper.

`compression:` is `:uncompressed` (the default), `:zstd`, or `:lz4`. `iounit_bytes:` defaults to 8 MiB and is rejected above 64 MiB as `:resource_limit`. `row_group_rows:` starts a new row group after at least that many rows. `checksum: true` stores a per-IOUnit xxHash.

You can also pass an `%F3.Batch{}` to `write/2`, or an `%F3.Schema{}` as `schema:`. A second `close/1` returns the same closed handle.

This library does not write Wasm into the file. After a successful close, `F3.open/2` and `F3.read/2` on that path are the check that the file round-trips. `F3.read/2` still needs the native decoder.
