# Runnable from the repository root:
#   mix run examples/tutorial_04.exs
#
# Projects two columns and takes the first batch. Without the native
# decoder the script reports that and exits.

IO.puts("command: mix run examples/tutorial_04.exs")

{:ok, file} = F3.open("test/fixtures/multi_row_group.f3")

case F3.stream(file, columns: ["trade_id"], batch_size: 2) do
  {:ok, stream} ->
    [batch] = Enum.take(stream, 1)
    IO.puts("batches taken: 1")
    IO.puts("batch rows: #{batch.num_rows}")
    IO.puts("columns: #{Enum.map_join(batch.schema.fields, ", ", & &1.name)}")
    {:ok, rows} = F3.Batch.to_rows(batch)
    IO.puts("to_rows of the first batch:")
    IO.inspect(rows, limit: :infinity)
    IO.puts("to_rows copies every value into a map. Keep the batch for a large file.")

  {:error, %F3.Error{category: :native_unavailable}} ->
    IO.puts("stream: native decoder is not loaded")
end

{:ok, _file} = F3.close(file)
