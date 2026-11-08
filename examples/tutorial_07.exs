# Runnable from the repository root:
#   mix run examples/tutorial_07.exs
#
# Jobs, not speeds. This script does not time Parquet or F3.

IO.puts("command: mix run examples/tutorial_07.exs")
IO.puts("arrow: in-memory columnar arrays, and the IPC schema in an F3 footer")
IO.puts("parquet: an interchange file this library does not read")
IO.puts("f3: a research file. Wasm stays off unless wasm: :sandbox")

{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, text} = F3.inspect(file)
{:ok, _} = F3.close(file)

text
|> String.split("\n", trim: true)
|> Enum.find(&String.starts_with?(&1, "schema:"))
|> IO.puts()

IO.puts("comparison: jobs, not speeds")
