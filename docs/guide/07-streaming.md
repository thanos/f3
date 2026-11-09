# Streaming

`F3.stream/2` returns a lazy stream of batches. It uses the same options as `F3.read/2`. The stream does not pread until the first pull. `Enum.take/2` stops further reads. You still call `F3.close/1`. The stream does not close the file.

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, stream} = F3.stream(file, columns: ["trade_id"], batch_size: 1024)

stream
|> Enum.take(1)
|> Enum.each(fn batch ->
  {:ok, _rows} = F3.Batch.to_rows(batch)
end)

{:ok, file} = F3.close(file)
```

The first pull reads the footer. Later pulls read encoding units. A pull that cannot decode throws `{:f3, %F3.Error{}}`. Wrap the consumption in `try` when you need that error as a value.

Without the native decoder, `F3.stream/2` returns `{:error, %F3.Error{category: :native_unavailable}}`. It does not return a stream. The message is `"native decoder is not loaded"`.

Pass the stream to `Stream` or `Flow` only after `{:ok, stream}`. A batch is columnar. Convert with `F3.Batch.to_rows/1` at the edge where a consumer needs maps. [Interoperability](10-interoperability.md) shows that handoff.
