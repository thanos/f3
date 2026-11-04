# Runnable from the repository root:
#   mix run examples/tutorial_01.exs

IO.puts("F3 Elixir is experimental.")
IO.puts("Upstream F3 is a research prototype and is not for production.")
IO.puts("Pinned wire version: #{F3.Format.major_version()}.#{F3.Format.minor_version()}")
IO.puts("Magic: #{inspect(F3.Format.magic())}")
IO.puts("Postscript size: #{F3.Format.postscript_size()} bytes")
IO.puts("Compatible with 0.1: #{F3.Format.compatible?(0, 1)}")
IO.puts("Reading rows: implemented when the native decoder is compiled")
IO.puts("Writing rows: not implemented")
