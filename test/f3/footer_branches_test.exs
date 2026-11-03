defmodule F3.FooterBranchesTest do
  use ExUnit.Case, async: true

  test "missing footer pieces and rejected sections are tagged errors" do
    assert {:error, %F3.Error{message: "schema is missing"}} = decode(table([]))

    assert {:error, %F3.Error{message: "Arrow message has no schema header"}} =
             decode(table([{:bytes, table([{:u8, 0}])}]))

    assert {:error, %F3.Error{message: "Arrow message header 4 is not a schema"}} =
             decode(table([{:bytes, table([{:u8, 0}, {:u8, 4}, {:table, [{:u8, 1}]}])}]))

    assert {:error, %F3.Error{message: "logical tree is missing"}} =
             decode(table([{:bytes, ipc()}]))

    assert {:error, %F3.Error{message: "row groups are missing"}} =
             decode(table([{:bytes, ipc()}, {:table, [{:u8, 0}]}]))

    assert {:error, %F3.Error{message: "repeated footer fields have different lengths"}} =
             decode(table([{:bytes, ipc()}, {:table, [{:u8, 0}]}, {:table, mismatched_groups()}]))

    assert {:error, %F3.Error{message: "encoding version is missing"}} =
             decode(footer([:absent, {:tables, [[{:u8, 7}]]}]))

    assert {:error, %F3.Error{message: "optional section starts past the postscript"}} =
             decode(footer([{:table, section("late", 9_999_999, 4, 0)}]))

    assert {:error, %F3.Error{message: "optional section overlaps the postscript"}} =
             decode(footer([{:table, section("over", 0, 9_999_999, 0)}]))

    assert {:error, %F3.Error{message: "column metadata size is empty"}} =
             decode(table([{:bytes, ipc()}, {:table, [{:u8, 0}]}, {:table, column_groups(0, 0)}]))

    assert {:error, %F3.Error{message: "column metadata is outside the metadata span"}} =
             decode(
               table([{:bytes, ipc()}, {:table, [{:u8, 0}]}, {:table, column_groups(100, 4)}])
             )

    assert {:error, %F3.Error{message: "column metadata overlaps the footer"}} =
             decode(
               table([{:bytes, ipc()}, {:table, [{:u8, 0}]}, {:table, column_groups(0, 20)}])
             )
  end

  test "unusual logical ids, compression, and an empty shared schema decode" do
    assert {:ok, listed} = decode(footer([]))
    assert listed.logical_tree.id == :list_of_struct_of_primitive

    assert {:ok, other} =
             decode(table([{:bytes, ipc()}, {:table, [{:u8, 9}]}, {:table, empty_groups()}]))

    assert other.logical_tree.id == 9

    assert {:ok, compressed} = decode(footer([{:table, section("notes", 0, 0, 9)}]))
    assert hd(compressed.optional_sections).compression == 9

    assert {:ok, shared} =
             decode(
               footer([
                 :absent,
                 {:tables, []},
                 {:table, [{:tables, []}, {:tables, [[{:u32s, [1]}]]}, {:bytes, <<>>}]}
               ])
             )

    assert shared.shared_dictionary.schema == nil
    assert shared.shared_dictionary.positions == [[1]]
  end

  defp footer(extra) do
    table([{:bytes, ipc()}, {:table, [{:u8, 3}]}, {:table, empty_groups()} | extra])
  end

  defp empty_groups do
    [{:u32s, []}, {:u64s, []}, {:u32s, []}, {:tables, []}]
  end

  defp mismatched_groups do
    [{:u32s, [1]}, {:u64s, []}, {:u32s, []}, {:tables, []}]
  end

  defp column_groups(offset, size) do
    [
      {:u32s, [1]},
      {:u64s, [0]},
      {:u32s, [1]},
      {:tables, [[{:tables, [[{:u64, offset}, {:u32, size}]]}]]}
    ]
  end

  defp section(name, offset, size, compression) do
    [{:strings, [name]}, {:u64s, [offset]}, {:u32s, [size]}, {:bytes, <<compression>>}]
  end

  defp decode(footer) do
    F3.Footer.decode(footer, %F3.Postscript{
      metadata_size: byte_size(footer),
      footer_size: byte_size(footer),
      footer_compression: :uncompressed,
      checksum_type: :xxhash,
      data_checksum: 0,
      schema_checksum: 0,
      major_version: 0,
      minor_version: 1,
      metadata_offset: 0,
      footer_offset: 0,
      file_size: byte_size(footer) + 32
    })
  end

  defp ipc do
    bytes = File.read!("test/fixtures/small.f3")
    size = byte_size(bytes)

    <<metadata_size::little-32, footer_size::little-32, _rest::binary>> =
      binary_part(bytes, size - 32, 32)

    span = binary_part(bytes, size - 32 - metadata_size, metadata_size)
    footer = binary_part(span, metadata_size - footer_size, footer_size)
    {:ok, root} = F3.FlatBuffer.root(footer)
    {:ok, ipc} = F3.FlatBuffer.bytes(root, 0)
    ipc
  end

  defp table(fields) do
    vtable_size = 4 + length(fields) * 2
    {body, payloads} = object(fields, vtable_size)

    vtable =
      <<vtable_size::little-16, byte_size(body)::little-16>> <>
        (fields |> field_slots() |> Enum.map(&<<&1::little-16>>) |> IO.iodata_to_binary())

    <<4 + vtable_size::little-32, vtable::binary, body::binary,
      IO.iodata_to_binary(payloads)::binary>>
  end

  defp object(fields, table_pos) do
    payload_at = table_pos + 4 + inline_size(fields)

    {body, payloads, _} =
      Enum.reduce(fields, {<<table_pos::little-signed-32>>, [], payload_at}, fn field, acc ->
        append(field, acc, table_pos)
      end)

    {body, payloads}
  end

  defp append(:absent, {body, payloads, payload_at}, _table_pos), do: {body, payloads, payload_at}

  defp append({:u8, value}, {body, payloads, payload_at}, _table_pos) do
    {body <> <<value>>, payloads, payload_at}
  end

  defp append({:u32, value}, {body, payloads, payload_at}, _table_pos) do
    {body <> <<value::little-32>>, payloads, payload_at}
  end

  defp append({:u64, value}, {body, payloads, payload_at}, _table_pos) do
    {body <> <<value::little-64>>, payloads, payload_at}
  end

  defp append({:bytes, raw}, {body, payloads, payload_at}, table_pos) do
    pointer({body, payloads, payload_at}, table_pos, <<byte_size(raw)::little-32, raw::binary>>)
  end

  defp append({:u32s, values}, {body, payloads, payload_at}, table_pos) do
    packed = IO.iodata_to_binary(Enum.map(values, &<<&1::little-32>>))

    pointer(
      {body, payloads, payload_at},
      table_pos,
      <<length(values)::little-32, packed::binary>>
    )
  end

  defp append({:u64s, values}, {body, payloads, payload_at}, table_pos) do
    packed = IO.iodata_to_binary(Enum.map(values, &<<&1::little-64>>))

    pointer(
      {body, payloads, payload_at},
      table_pos,
      <<length(values)::little-32, packed::binary>>
    )
  end

  defp append({:strings, values}, acc, table_pos) do
    append_vector(acc, table_pos, values, fn text ->
      <<byte_size(text)::little-32, text::binary>>
    end)
  end

  defp append({:table, fields}, {body, payloads, payload_at}, table_pos) do
    child = child_bytes(fields)
    <<vtable_size::little-16, _::binary>> = child
    relative = payload_at + vtable_size - (table_pos + byte_size(body))
    {body <> <<relative::little-32>>, payloads ++ [child], payload_at + byte_size(child)}
  end

  defp append({:tables, items}, acc, table_pos) do
    append_vector(acc, table_pos, items, fn fields ->
      child = child_bytes(fields)
      <<vtable_size::little-16, _::binary>> = child
      {vtable_size, child}
    end)
  end

  defp append_vector({body, payloads, payload_at}, table_pos, items, encoder) do
    built = Enum.map(items, encoder)
    entries_at = payload_at + 4
    blobs_at = entries_at + length(items) * 4

    {words, blobs, _at} =
      Enum.reduce(built, {[], [], blobs_at}, fn item, {words, blobs, at} ->
        {skip, blob} =
          case item do
            {skip, blob} when is_integer(skip) and is_binary(blob) -> {skip, blob}
            blob when is_binary(blob) -> {0, blob}
          end

        relative = at + skip - (entries_at + length(words) * 4)
        {[<<relative::little-32>> | words], [blobs, blob], at + byte_size(blob)}
      end)

    payload =
      <<length(items)::little-32, IO.iodata_to_binary(Enum.reverse(words))::binary,
        IO.iodata_to_binary(blobs)::binary>>

    pointer({body, payloads, payload_at}, table_pos, payload)
  end

  defp pointer({body, payloads, payload_at}, table_pos, payload) do
    relative = payload_at - (table_pos + byte_size(body))
    {body <> <<relative::little-32>>, payloads ++ [payload], payload_at + byte_size(payload)}
  end

  defp child_bytes(fields) do
    vtable_size = 4 + length(fields) * 2
    {body, payloads} = object(fields, vtable_size)

    vtable =
      <<vtable_size::little-16, byte_size(body)::little-16>> <>
        (fields |> field_slots() |> Enum.map(&<<&1::little-16>>) |> IO.iodata_to_binary())

    IO.iodata_to_binary([vtable, body, payloads])
  end

  defp field_slots(fields) do
    {slots, _cursor} =
      Enum.map_reduce(fields, 4, fn
        :absent, cursor -> {0, cursor}
        field, cursor -> {cursor, cursor + inline_width(field)}
      end)

    slots
  end

  defp inline_size(fields) do
    Enum.reduce(fields, 0, fn field, acc -> acc + inline_width(field) end)
  end

  defp inline_width(:absent), do: 0
  defp inline_width({:u8, _}), do: 1
  defp inline_width({:u64, _}), do: 8
  defp inline_width(_field), do: 4
end
