# Runnable from the repository root:
#   mix run examples/tutorial_05.exs
#
# Writes one row when the native writer is loaded. The default build prints
# that the writer is not loaded and creates no file.

IO.puts("command: mix run examples/tutorial_05.exs")

schema = [trade_id: :int64, symbol: :utf8, price: {:float64, null: true}]

if File.read("native/f3_native/.f3_build_native") == {:ok, "1"} do
  path = Path.join(System.tmp_dir!(), "f3-tutorial-05-#{System.unique_integer([:positive])}.f3")

  {:ok, writer} = F3.Writer.open(path, schema: schema, compression: :zstd)
  :ok = F3.Writer.write(writer, [%{trade_id: 1, symbol: "AAPL", price: nil}])
  {:ok, _writer} = F3.Writer.close(writer)

  {:ok, file} = F3.open(path)
  {:ok, [batch]} = F3.read(file)
  {:ok, rows} = F3.Batch.to_rows(batch)
  {:ok, _} = F3.close(file)
  File.rm(path)

  IO.puts("write: round trip")
  IO.inspect(rows, limit: :infinity)
else
  IO.puts("write: native writer is not loaded")
end
