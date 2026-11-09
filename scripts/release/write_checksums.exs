# Writes the checksum files a Hex package uses to download precompiled
# archives. The argument is the directory of .tar.gz files. Checksums are
# written in the current directory.
#
#   elixir scripts/release/write_checksums.exs assets

defmodule F3.Release.Checksums do
  @moduledoc false

  def write!(directory) do
    archives = Path.wildcard(Path.join(directory, "*.tar.gz"))
    native = select(archives, "libf3_native-")
    writer = select(archives, "f3_write-")

    if map_size(native) == 0 or map_size(writer) == 0 do
      IO.puts(:stderr, "expected libf3_native and f3_write archives in #{directory}")
      System.halt(1)
    end

    dump!("checksum-Elixir.F3.Native.exs", native)
    dump!("checksum-f3_write.exs", writer)
  end

  defp select(archives, prefix) do
    for path <- archives,
        name = Path.basename(path),
        String.starts_with?(name, prefix),
        into: %{},
        do: {name, checksum(path)}
  end

  defp checksum(path) do
    hash =
      path
      |> File.read!()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    "sha256:" <> hash
  end

  defp dump!(path, map) do
    lines =
      map
      |> Enum.sort()
      |> Enum.map(fn {name, hash} -> ~s(  "#{name}" => "#{hash}",) end)

    File.write!(path, Enum.join(["%{" | lines] ++ ["}"], "\n") <> "\n")
    IO.puts("wrote #{path}")
  end
end

[directory] = System.argv()
F3.Release.Checksums.write!(directory)
