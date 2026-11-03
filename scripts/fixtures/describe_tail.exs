defmodule F3.FixtureTail do
  @moduledoc false

  @doc """
  Prints the 32-byte postscript of an F3 fixture. This is a dump of the
  pinned field widths, not the Stage 1 parser.
  """
  def run(path) do
    case File.read(path) do
      {:ok, bytes} -> print(path, bytes)
      {:error, reason} -> fail!("cannot read #{path}: #{inspect(reason)}")
    end
  end

  defp print(path, bytes) do
    postscript_size = F3.Format.postscript_size()

    if byte_size(bytes) < postscript_size do
      fail!("#{path} is shorter than the postscript")
    end

    offset = byte_size(bytes) - postscript_size
    tail = binary_part(bytes, offset, postscript_size)
    fields = decode(tail)

    if fields.magic != F3.Format.magic() do
      fail!("magic is #{inspect(fields.magic)}")
    end

    unless F3.Format.compatible?(fields.major_version, fields.minor_version) do
      fail!(
        "version #{fields.major_version}.#{fields.minor_version} is outside the pinned policy"
      )
    end

    sha =
      :crypto.hash(:sha256, bytes)
      |> Base.encode16(case: :lower)

    IO.puts("fixture: #{path}")
    IO.puts("bytes: #{byte_size(bytes)}")
    IO.puts("sha256: #{sha}")
    IO.puts("postscript_offset: #{offset}")
    IO.puts("postscript_size: #{postscript_size}")
    IO.puts("metadata_size: #{fields.metadata_size}")
    IO.puts("footer_size: #{fields.footer_size}")
    IO.puts("footer_compression: #{fields.footer_compression}")
    IO.puts("checksum_type: #{fields.checksum_type}")
    IO.puts("data_checksum: 0x#{hex64(fields.data_checksum)}")
    IO.puts("schema_checksum: 0x#{hex64(fields.schema_checksum)}")
    IO.puts("major_version: #{fields.major_version}")
    IO.puts("minor_version: #{fields.minor_version}")
    IO.puts("magic: #{fields.magic}")
    IO.puts("tail_hex:")
    IO.puts(hexdump(tail, offset))
  end

  defp decode(tail) do
    {fields, rest} =
      Enum.reduce(F3.Format.postscript_layout(), {[], tail}, fn {name, width}, {acc, rest} ->
        <<raw::binary-size(^width), rest::binary>> = rest
        {[{name, decode_field(name, raw)} | acc], rest}
      end)

    if rest != "" do
      fail!("postscript layout did not consume #{byte_size(rest)} trailing bytes")
    end

    Map.new(fields)
  end

  defp decode_field(:magic, raw), do: raw
  defp decode_field(:footer_compression, <<value>>), do: value
  defp decode_field(:checksum_type, <<value>>), do: value

  defp decode_field(name, raw) when name in [:metadata_size, :footer_size] do
    <<value::little-unsigned-integer-size(32)>> = raw
    value
  end

  defp decode_field(name, raw) when name in [:data_checksum, :schema_checksum] do
    <<value::little-unsigned-integer-size(64)>> = raw
    value
  end

  defp decode_field(name, raw) when name in [:major_version, :minor_version] do
    <<value::little-unsigned-integer-size(16)>> = raw
    value
  end

  defp hex64(value) do
    value
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(16, "0")
  end

  defp hexdump(tail, offset) do
    tail
    |> :binary.bin_to_list()
    |> Enum.chunk_every(16)
    |> Enum.with_index()
    |> Enum.map_join("\n", fn {chunk, index} ->
      hex = Enum.map_join(chunk, " ", &byte_hex/1)
      address = offset + index * 16
      "  #{address_hex(address)}: #{hex}"
    end)
  end

  defp byte_hex(byte) do
    byte
    |> Integer.to_string(16)
    |> String.downcase()
    |> String.pad_leading(2, "0")
  end

  defp address_hex(address) do
    address
    |> Integer.to_string(16)
    |> String.pad_leading(8, "0")
  end

  defp fail!(message) do
    if System.get_env("MIX_ENV") == "test" do
      raise message
    else
      IO.puts(:stderr, message)
      System.halt(1)
    end
  end
end

fixture = System.get_env("F3_FIXTURE", "test/fixtures/small.f3")
F3.FixtureTail.run(fixture)
