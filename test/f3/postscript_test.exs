defmodule F3.PostscriptTest do
  use ExUnit.Case, async: true

  test "a file shorter than 32 bytes is truncated at every tail length" do
    for length <- 0..31 do
      assert {:error, %F3.Error{category: :truncated}} = open_memory(:binary.copy(<<0>>, length))
    end
  end

  test "cutting a real file at each postscript boundary returns a tagged error" do
    bytes = File.read!("test/fixtures/small.f3")

    for drop <- 1..32 do
      shortened = binary_part(bytes, 0, byte_size(bytes) - drop)

      assert {:error, %F3.Error{category: category}} = open_memory(shortened)
      assert category in [:truncated, :invalid_magic, :corrupt_metadata, :unsupported_version]
    end
  end

  test "magic, version, compression, sizes, and an unknown checksum" do
    assert {:error, %F3.Error{category: :invalid_magic}} =
             open_memory(file(8, 8, compression: 0, magic: "XX"))

    assert {:error, %F3.Error{category: :unsupported_version}} =
             open_memory(file(8, 8, minor: 2))

    assert {:error, %F3.Error{category: :unsupported_version}} =
             open_memory(file(8, 8, major: 1))

    assert {:error, %F3.Error{category: :unsupported_encoding}} =
             open_memory(file(8, 8, compression: 1))

    assert {:error, %F3.Error{category: :corrupt_metadata}} = open_memory(file(50, 100))
    assert {:error, %F3.Error{category: :corrupt_metadata}} = open_memory(file(0, 0))

    assert {:error, %F3.Error{category: :truncated}} = open_memory(file(1_000, 100))

    assert {:error, %F3.Error{category: :resource_limit}} =
             open_memory(file(20_000_000, 20_000_000))

    assert {:ok, file} = F3.open({:memory, file(8, 8, checksum: 7)})
    assert {:ok, postscript} = F3.Postscript.decode(file, F3.Postscript.max_metadata_bytes())
    assert postscript.checksum_type == {:unknown, 7}
    assert postscript.footer_compression == :uncompressed
  end

  test "the cap is per call and refuses a real footer that exceeds it" do
    assert {:error, %F3.Error{category: :resource_limit}} =
             F3.metadata(open_path!("test/fixtures/small.f3"), max_metadata_bytes: 32)

    assert {:ok, _metadata} =
             F3.metadata(open_path!("test/fixtures/small.f3"), max_metadata_bytes: 2_000)
  end

  defp open_memory(bytes) do
    assert {:ok, file} = F3.open({:memory, bytes})
    F3.metadata(file)
  end

  defp open_path!(path) do
    assert {:ok, file} = F3.open(path)
    file
  end

  defp file(metadata_size, footer_size, opts \\ []) do
    padding = :binary.copy(<<0>>, 8)
    compression = Keyword.get(opts, :compression, 0)
    checksum = Keyword.get(opts, :checksum, 0)
    minor = Keyword.get(opts, :minor, 1)
    major = Keyword.get(opts, :major, 0)
    magic = Keyword.get(opts, :magic, "F3")

    padding <>
      <<metadata_size::little-32, footer_size::little-32, compression, checksum, 0::little-64,
        0::little-64, major::little-16, minor::little-16, magic::binary>>
  end
end
