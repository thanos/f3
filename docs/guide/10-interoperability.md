# Interoperability

A decoded batch is an Elixir term. `batch.columns` maps a field name to an `F3.Column`. `F3.Batch.to_rows/1` turns one batch into a list of maps. Integers, floats, booleans, UTF-8 binaries, lists, and maps are the values. Nulls are `nil`.

This library does not return Arrow arrays, Explorer frames, Nx tensors, or Zarr stores. It does not read or write Parquet. The Arrow schema in the footer is metadata. `F3.schema/1` returns that schema so you can name fields and types. The column bytes do not cross the native boundary as Arrow buffers.

`ex_arrow` and ExZarr are not dependencies of `:f3`, and this page does not call them. The values below are what you would hand to an Arrow or Zarr library after a read: one column of integers, floats, booleans, or binaries, already owned by Elixir.

## Streams

`F3.stream/2` is already lazy. Turn a batch into rows at the edge that needs maps:

```elixir
{:ok, stream} = F3.stream(file, columns: ["price"])

prices =
  stream
  |> Stream.flat_map(fn batch ->
    {:ok, rows} = F3.Batch.to_rows(batch)
    Stream.map(rows, & &1["price"])
  end)
```

That `{:ok, stream}` requires the native decoder. A failed pull throws `{:f3, %F3.Error{}}`.

## Flow

`Flow.from_enumerable/1` accepts that same stream. Partition only after you know the file is large enough to pay for it. Close the `F3.File` when the flow finishes. The flow does not own the handle.

```elixir
{:ok, stream} = F3.stream(file)

symbols =
  stream
  |> Flow.from_enumerable()
  |> Flow.flat_map(fn batch ->
    {:ok, rows} = F3.Batch.to_rows(batch)
    Enum.map(rows, & &1["symbol"])
  end)
  |> Enum.to_list()
```

## Explorer and Nx

Explorer and Nx are separate packages. A list of row maps is the input their constructors already accept. Build it from a batch you have already decoded:

```elixir
{:ok, rows} = F3.Batch.to_rows(batch)

frame = Explorer.DataFrame.new(rows)
prices = Nx.tensor(Enum.map(rows, & &1["price"]))
```

Prefer `batch.columns` when you only need one numeric column and the row count is large. `F3.Column.value/2` reads one row. Walking every row into a list, then into Nx, copies the column. Do that at the boundary, not inside the read loop, and only for a column that fits in memory.

## Arrow and Zarr

The footer schema is an Arrow IPC schema. A caller that builds Arrow arrays uses the field names from `F3.schema/1` and the Elixir values from `F3.Column` or `to_rows/1`. A caller that writes Zarr uses those same column values as the chunk payload. This library does not open a Zarr store, and it does not call an Arrow C interface. Parquet remains a different file. Nothing in `F3.open/2` or `F3.Writer` reads or writes one.
