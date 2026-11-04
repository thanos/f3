# Runnable from the repository root:
#   mix run examples/tutorial_03.exs
#
# Opens the committed small fixture, prints schema and metadata, and reads
# rows when the native decoder is loaded.

IO.puts("command: mix run examples/tutorial_03.exs")

{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, schema} = F3.schema(file)
{:ok, metadata} = F3.metadata(file)

IO.puts("fields:")

Enum.each(schema.fields, fn field ->
  mark = if field.nullable, do: " nullable", else: ""
  IO.puts("  #{field.name} #{F3.Schema.type_label(field.type)}#{mark}")
end)

IO.puts("row_groups: #{length(metadata.row_groups)}")
IO.puts("rows: #{Enum.reduce(metadata.row_groups, 0, fn group, acc -> acc + group.num_rows end)}")

case F3.read(file) do
  {:ok, batches} ->
    rows =
      Enum.flat_map(batches, fn batch ->
        {:ok, rows} = F3.Batch.to_rows(batch)
        rows
      end)

    IO.puts("read:")
    IO.inspect(rows, limit: :infinity)

  {:error, %F3.Error{category: :native_unavailable}} ->
    IO.puts("read: native decoder is not loaded")
end

{:ok, text} = F3.inspect(file)
IO.puts("inspect:")
IO.puts(text)

{:ok, file} = F3.close(file)
{:error, %F3.Error{category: :closed}} = F3.schema(file)
IO.puts("after close: closed")
