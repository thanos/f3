# Runnable from the repository root:
#   mix run examples/tutorial_08.exs
#
# Prints the real postscript cap, the dirty-CPU gate, and the Wasm default.

IO.puts("command: mix run examples/tutorial_08.exs")
IO.puts("max_metadata_bytes: #{F3.Postscript.max_metadata_bytes()}")
IO.puts("nif: dirty CPU when F3_BUILD_NATIVE=1")
IO.puts("wasm: off unless wasm: :sandbox")

{:ok, file} = F3.open("test/fixtures/small.f3")

read =
  case F3.read(file) do
    {:ok, _batches} -> "ok"
    {:error, %F3.Error{category: category}} -> Atom.to_string(category)
  end

{:ok, _} = F3.close(file)
IO.puts("read: #{read}")
IO.puts("http: opt-in, redirects refused, lib_urls unread")
