defmodule F3.MetadataTest do
  use ExUnit.Case, async: true

  @fixtures ~w(small nullable wide multi_row_group compressed_zstd compressed_lz4 dictionary nested)

  test "decoded metadata matches the upstream reader" do
    for name <- @fixtures do
      {:ok, file} = F3.open("test/fixtures/#{name}.f3")
      assert {:ok, metadata} = F3.metadata(file)
      assert {:ok, golden} = File.read("test/fixtures/golden/#{name}.json")
      assert {:ok, expected} = JSON.decode(golden)
      assert F3.Metadata.to_map(metadata) == expected
    end
  end

  test "small.f3 exposes the logical schema, one row group, and cascade units" do
    metadata = metadata!("small.f3")

    assert Enum.map(metadata.schema.fields, & &1.name) == ["trade_id", "symbol", "price"]

    assert Enum.map(metadata.schema.fields, & &1.type) == [
             {:int, 64, true},
             :utf8,
             {:float, :double}
           ]

    assert [%F3.RowGroup{num_rows: 3, columns: columns}] = metadata.row_groups
    assert Enum.map(columns, & &1.name) == ["trade_id", "symbol", "price"]

    assert Enum.all?(columns, fn column ->
             hd(column.chunks).encunits |> hd() |> Map.fetch!(:encoding) == :cascade
           end)

    assert metadata.checksum_type == :xxhash
    assert metadata.footer_compression == :uncompressed

    assert Enum.map(metadata.encoding_versions, & &1.encoding) |> Enum.sort() == [
             :cascade,
             :custom_wasm
           ]

    assert [%{name: "WASMBinaries"}] = metadata.optional_sections
  end

  test "nullable, wide, compressed, dictionary, nested, and multi row group shapes" do
    nullable = metadata!("nullable.f3")
    assert Enum.all?(nullable.schema.fields, & &1.nullable)

    wide = metadata!("wide.f3")
    assert length(wide.schema.fields) == 16
    assert length(hd(wide.row_groups).columns) == 16

    assert compression_of("compressed_zstd.f3") == :zstd
    assert compression_of("compressed_lz4.f3") == :lz4

    dictionary = metadata!("dictionary.f3")

    assert Enum.all?(dictionary.row_groups, fn group ->
             Enum.all?(group.columns, fn column ->
               match?({:local, _indexes}, hd(column.chunks).dictionary)
             end)
           end)

    nested = metadata!("nested.f3")

    assert [%{name: "trade", type: {:struct, trade_fields}}, %{name: "nums", type: {:list, nums}}] =
             nested.schema.fields

    assert Enum.map(trade_fields, & &1.name) == ["b", "c"]
    assert nums.type == {:int, 32, true}
    assert length(hd(nested.row_groups).columns) == 5
    assert Enum.all?(hd(nested.row_groups).columns, &is_nil(&1.name))

    groups = metadata!("multi_row_group.f3").row_groups
    assert Enum.map(groups, & &1.num_rows) == [2, 1]
  end

  test "read reports native_unavailable when the NIF is absent" do
    {:ok, file} = F3.open("test/fixtures/small.f3")
    assert {:error, %F3.Error{category: :native_unavailable}} = F3.read(file)
    assert {:error, %F3.Error{category: :native_unavailable}} = F3.stream(file)
  end

  test "inspect text and json agree with the metadata map" do
    {:ok, file} = F3.open("test/fixtures/small.f3")
    assert {:ok, text} = F3.inspect(file)
    assert text =~ "schema: trade_id int64, symbol utf8, price float64"
    assert text =~ "rows: 3"
    refute text =~ "chunk offset"

    assert {:ok, detail} = F3.inspect(file, detail: true)
    assert detail =~ "column 0 trade_id"
    assert detail =~ "encoding=cascade"

    assert {:ok, json} = F3.inspect(file, format: :json)
    assert {:ok, metadata} = F3.metadata(file)
    assert JSON.decode!(json) == F3.Metadata.to_map(metadata)
  end

  test "a memory copy of a fixture decodes the same metadata" do
    bytes = File.read!("test/fixtures/nullable.f3")
    assert {:ok, memory} = F3.open({:memory, bytes})
    assert {:ok, disk} = F3.open("test/fixtures/nullable.f3")
    assert {:ok, from_memory} = F3.metadata(memory)
    assert {:ok, from_disk} = F3.metadata(disk)
    assert F3.Metadata.to_map(from_memory) == F3.Metadata.to_map(from_disk)
  end

  test "corrupt footer root, vtable, and column metadata are tagged errors" do
    bytes = File.read!("test/fixtures/small.f3")
    postscript = postscript!(bytes)

    root = put_u32(bytes, postscript.footer_offset, 0x7FFFFFFF)
    assert {:error, %F3.Error{category: :corrupt_metadata} = error} = open_memory(root)
    refute error.message =~ "trade_id"

    vtable = put_i32(bytes, postscript.footer_offset + u32_at(bytes, postscript.footer_offset), 0)
    assert {:error, %F3.Error{category: :corrupt_metadata}} = open_memory(vtable)

    column = zero_range(bytes, postscript.metadata_offset, postscript.footer_offset)
    assert {:error, %F3.Error{category: :corrupt_metadata}} = open_memory(column)
  end

  test "random bytes return a tagged error" do
    :rand.seed(:exsss, {1, 2, 3})

    for _ <- 1..80 do
      bytes = random_bytes(:rand.uniform(96) - 1)
      assert {:error, %F3.Error{}} = open_memory(bytes)
    end
  end

  test "a synthetic footer with an empty row-group vector" do
    bytes = empty_row_group_file()
    assert {:ok, file} = F3.open({:memory, bytes})
    assert {:ok, metadata} = F3.metadata(file)
    assert metadata.row_groups == []
    assert Enum.map(metadata.schema.fields, & &1.name) == ["trade_id", "symbol", "price"]
    assert metadata.logical_tree.id == :flat
  end

  defp metadata!(name) do
    assert {:ok, file} = F3.open("test/fixtures/#{name}")
    assert {:ok, metadata} = F3.metadata(file)
    metadata
  end

  defp compression_of(name) do
    name
    |> metadata!()
    |> Map.fetch!(:row_groups)
    |> hd()
    |> Map.fetch!(:columns)
    |> hd()
    |> Map.fetch!(:chunks)
    |> hd()
    |> Map.fetch!(:encunits)
    |> hd()
    |> Map.fetch!(:compression)
  end

  defp open_memory(bytes) do
    assert {:ok, file} = F3.open({:memory, bytes})
    F3.metadata(file)
  end

  defp postscript!(bytes) do
    assert {:ok, file} = F3.open({:memory, bytes})
    assert {:ok, postscript} = F3.Postscript.decode(file, F3.Postscript.max_metadata_bytes())
    postscript
  end

  defp put_u32(bytes, offset, value) do
    splice(bytes, offset, <<value::little-32>>)
  end

  defp put_i32(bytes, offset, value) do
    splice(bytes, offset, <<value::little-signed-32>>)
  end

  defp u32_at(bytes, offset) do
    <<value::little-32>> = binary_part(bytes, offset, 4)
    value
  end

  defp splice(bytes, offset, replacement) do
    head = binary_part(bytes, 0, offset)

    tail =
      binary_part(
        bytes,
        offset + byte_size(replacement),
        byte_size(bytes) - offset - byte_size(replacement)
      )

    head <> replacement <> tail
  end

  defp zero_range(bytes, from, to) do
    binary_part(bytes, 0, from) <>
      :binary.copy(<<0>>, to - from) <>
      binary_part(bytes, to, byte_size(bytes) - to)
  end

  defp random_bytes(0), do: <<>>

  defp random_bytes(length) do
    :binary.list_to_bin(for _ <- 1..length, do: :rand.uniform(256) - 1)
  end

  # Synthetic FlatBuffers footer. The Arrow IPC bytes are copied from the
  # committed small.f3 file. The row-group vectors are empty. This is not
  # an upstream fixture.
  defp empty_row_group_file do
    ipc = schema_ipc!("test/fixtures/small.f3")
    footer = synthetic_footer(ipc)

    footer <>
      <<byte_size(footer)::little-32, byte_size(footer)::little-32, 0, 0, 0::little-64,
        0::little-64, 0::little-16, 1::little-16, "F3">>
  end

  defp schema_ipc!(path) do
    bytes = File.read!(path)
    postscript = postscript!(bytes)
    span = binary_part(bytes, postscript.metadata_offset, postscript.metadata_size)
    footer = binary_part(span, byte_size(span) - postscript.footer_size, postscript.footer_size)
    {:ok, root} = F3.FlatBuffer.root(footer)
    {:ok, ipc} = F3.FlatBuffer.bytes(root, 0)
    ipc
  end

  defp synthetic_footer(ipc) do
    bin = ""
    {bin, schema_at} = place_bytes_vector(bin, ipc)
    {bin, empty_at} = place(bin, <<0::little-32>>)
    {bin, tree_at} = place_tree(bin)
    {bin, groups_at} = place_row_groups(bin, empty_at)
    {bin, footer_at} = place_footer(bin, schema_at, tree_at, groups_at)
    root = byte_size(bin) + 4 - footer_at
    <<root::little-32, bin::binary>>
  end

  defp place(bin, bytes), do: {bytes <> bin, byte_size(bytes) + byte_size(bin)}

  defp place_bytes_vector(bin, bytes) do
    bin = bytes <> bin
    place(bin, <<byte_size(bytes)::little-32>>)
  end

  defp place_tree(bin) do
    {bin, vtable_at} = place(bin, <<6::little-16, 5::little-16, 4::little-16>>)
    table_at = byte_size(bin) + 5
    soffset = vtable_at - table_at
    place(bin, <<soffset::little-signed-32, 0>>)
  end

  defp place_row_groups(bin, empty_at) do
    vtable =
      <<12::little-16, 20::little-16, 4::little-16, 8::little-16, 12::little-16, 16::little-16>>

    {bin, vtable_at} = place(bin, vtable)
    table_at = byte_size(bin) + 20
    soffset = vtable_at - table_at

    offsets =
      for field <- [4, 8, 12, 16] do
        <<table_at - field - empty_at::little-32>>
      end
      |> IO.iodata_to_binary()

    place(bin, <<soffset::little-signed-32, offsets::binary>>)
  end

  defp place_footer(bin, schema_at, tree_at, groups_at) do
    vtable = <<10::little-16, 16::little-16, 4::little-16, 8::little-16, 12::little-16>>
    {bin, vtable_at} = place(bin, vtable)
    table_at = byte_size(bin) + 16
    soffset = vtable_at - table_at

    fields =
      [schema_at, tree_at, groups_at]
      |> Enum.with_index()
      |> Enum.map(fn {target, index} ->
        field = 4 + index * 4
        <<table_at - field - target::little-32>>
      end)
      |> IO.iodata_to_binary()

    place(bin, <<soffset::little-signed-32, fields::binary>>)
  end
end
