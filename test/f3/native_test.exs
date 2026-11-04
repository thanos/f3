defmodule F3.NativeTest do
  use ExUnit.Case, async: false

  @moduletag :native

  @fixtures ~w(
    small
    nullable
    wide
    nested
    dictionary
    multi_row_group
    compressed_zstd
    compressed_lz4
  )

  test "the NIF is loaded and does not require fff-poc" do
    assert {:ok, {"f3_native", "0.0.1"}} = F3.Native.info()
    assert F3.Native.available?()
  end

  test "every committed fixture matches the manifest and the upstream golden rows" do
    manifest = File.read!("test/fixtures/manifest.json") |> :json.decode()
    fixtures = Map.fetch!(manifest, "fixtures")

    for name <- @fixtures do
      path = "test/fixtures/#{name}.f3"
      entry = Enum.find(fixtures, &(&1["name"] == "#{name}.f3"))
      {:ok, file} = F3.open(path)
      assert {:ok, batches} = F3.read(file)

      rows =
        Enum.flat_map(batches, fn batch ->
          {:ok, rows} = F3.Batch.to_rows(batch)
          rows
        end)

      golden_path = "test/fixtures/golden/#{name}_rows.json"

      if File.exists?(golden_path) do
        assert rows == golden_path |> File.read!() |> :json.decode() |> nulls_to_nil()
      else
        # The pinned FileReaderV2 panics on dictionary.f3 ("Incorrect type of indices").
        assert name == "dictionary"
      end

      assert rows == manifest_rows(entry)
    end
  end

  test "projection, a second reader, and an early take use the native decoder" do
    {:ok, first} = F3.open("test/fixtures/small.f3")
    {:ok, second} = F3.open("test/fixtures/small.f3")
    assert {:ok, [batch]} = F3.read(first, columns: ["symbol"])
    assert Enum.map(batch.schema.fields, & &1.name) == ["symbol"]
    assert {:ok, rows} = F3.Batch.to_rows(batch)
    assert rows == [%{"symbol" => "AAPL"}, %{"symbol" => "MSFT"}, %{"symbol" => "GOOG"}]
    assert {:ok, [%F3.Batch{num_rows: 3}]} = F3.read(second)

    {:ok, grouped} = F3.open("test/fixtures/multi_row_group.f3")
    assert {:ok, stream} = F3.stream(grouped)
    assert [%F3.Batch{num_rows: 2}] = Enum.take(stream, 1)
  end

  test "a corrupt encoding unit is a tagged error and the caller stays alive" do
    assert {:error, message} = F3.Native.decode_encunit(<<0, 0, 0, 0>>, :uncompressed, :i64)
    assert is_binary(message)

    assert {:error, %F3.Error{category: :unsupported_encoding}} =
             F3.Native.apply_decode(<<>>, :gzip, :i64)

    bytes = File.read!("test/fixtures/small.f3")
    wiped = <<0::size(1664 * 8)>> <> binary_part(bytes, 1664, byte_size(bytes) - 1664)
    {:ok, file} = F3.open({:memory, wiped})
    assert {:error, %F3.Error{category: :corrupt}} = F3.read(file)
    assert Process.alive?(self())
  end

  defp manifest_rows(entry) do
    names = Enum.map(entry["schema"], & &1["name"])

    Enum.map(entry["rows"], fn row ->
      names |> Enum.zip(row) |> Map.new(fn {name, value} -> {name, manifest_value(value)} end)
    end)
  end

  defp nulls_to_nil(:null), do: nil

  defp nulls_to_nil(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, nulls_to_nil(nested)} end)
  end

  defp nulls_to_nil(value) when is_list(value), do: Enum.map(value, &nulls_to_nil/1)
  defp nulls_to_nil(value), do: value

  defp manifest_value(:null), do: nil
  defp manifest_value(nil), do: nil

  defp manifest_value(value) when is_map(value) do
    Map.new(value, fn {key, nested} -> {key, manifest_value(nested)} end)
  end

  defp manifest_value(value) when is_list(value), do: Enum.map(value, &manifest_value/1)

  defp manifest_value(value) when is_float(value) or is_integer(value), do: value
  defp manifest_value(value) when is_binary(value), do: value
end
