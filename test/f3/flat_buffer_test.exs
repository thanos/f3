defmodule F3.FlatBufferTest do
  use ExUnit.Case, async: true

  alias F3.FlatBuffer, as: FB

  defp root!(bin) do
    {:ok, table} = FB.root(bin)
    table
  end

  test "scalars, strings, vectors, and unions round-trip a hand-built table" do
    {:ok, root} =
      FB.root(
        table([
          {:u32, 42},
          {:bool, true},
          {:u8, 7},
          {:i16, -2},
          {:u16, 9},
          {:i32, -4},
          {:u64, 99}
        ])
      )

    assert {:ok, 42} = FB.scalar(root, 0, :u32, 0)
    assert {:ok, true} = FB.scalar(root, 1, :bool, false)
    assert {:ok, false} = FB.scalar(root!(table([{:bool, false}])), 0, :bool, true)
    assert {:ok, 7} = FB.scalar(root, 2, :u8, 0)
    assert {:ok, -2} = FB.scalar(root, 3, :i16, 0)
    assert {:ok, 9} = FB.scalar(root, 4, :u16, 0)
    assert {:ok, -4} = FB.scalar(root, 5, :i32, 0)
    assert {:ok, 99} = FB.scalar(root, 6, :u64, 0)
    assert {:ok, nil} = FB.optional_scalar(root, 7, :u32)
    assert {:ok, 5} = FB.scalar(root, 7, :u32, 5)

    {:ok, strings} =
      FB.root(
        table([
          {:string, "hi"},
          {:bytes, <<0xFF>>},
          {:u32s, [3, 4]},
          {:strings, ["a", "b"]}
        ])
      )

    assert {:ok, "hi"} = FB.string(strings, 0)
    assert {:error, :corrupt} = FB.string(strings, 1)
    assert {:ok, <<0xFF>>} = FB.bytes(strings, 1)
    assert {:ok, [3, 4]} = FB.uints(strings, 2, 4)
    assert {:ok, [8]} = FB.uints(root!(table([{:u64s, [8]}])), 0, 8)
    assert {:ok, ["a", "b"]} = FB.string_vector(strings, 3)
    assert {:ok, []} = FB.string_vector(strings, 4)
    assert {:ok, []} = FB.uints(strings, 4, 4)
    assert {:ok, []} = FB.tables(strings, 4)
    assert {:ok, nil} = FB.bytes(strings, 4)

    {:ok, none} = FB.root(table([{:u8, 0}]))
    assert {:ok, :none} = FB.union(none, 0)
    assert {:ok, nil} = FB.table(none, 1)

    {:ok, tagged} = FB.root(table([{:u8, 2}, {:table, [{:u32, 11}]}]))
    assert {:ok, {2, child}} = FB.union(tagged, 0)
    assert {:ok, 11} = FB.scalar(child, 0, :u32, 0)

    assert {:error, :corrupt} = FB.union(root!(table([{:u8, 2}])), 0)
  end

  test "a shared vtable after the table is readable" do
    vtable = <<6::little-16, 8::little-16, 4::little-16>>
    table = <<-8::little-signed-32, 7::little-32>>
    bin = <<4::little-32, table::binary, vtable::binary>>

    assert {:ok, root} = FB.root(bin)
    assert {:ok, 7} = FB.scalar(root, 0, :u32, 0)
  end

  test "corrupt offsets, a huge vector, and a deep chain stop" do
    assert {:error, :corrupt} = FB.root(:not_a_binary)
    assert {:error, :corrupt} = FB.root(<<>>)
    assert {:error, :corrupt} = FB.root(<<0::little-32, 0, 0, 0, 0>>)
    assert {:error, :corrupt} = FB.root(<<4::little-32, 0::little-signed-32>>)
    assert {:error, :corrupt} = FB.root(<<4::little-32, -20::little-signed-32, 0, 0>>)

    huge = overwrite_length(table([{:u32s, [1]}]), 1_000_001)
    assert {:error, :corrupt} = FB.uints(root!(huge), 0, 4)

    assert {:error, :depth} = walk(table(nest(40)), 40)
  end

  defp nest(0), do: [{:u32, 1}]
  defp nest(n), do: [{:table, nest(n - 1)}]

  defp walk(bin, times) do
    Enum.reduce_while(1..times, root!(bin), fn _, table ->
      case FB.table(table, 0) do
        {:ok, child} -> {:cont, child}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp overwrite_length(bin, value) do
    # One reference field: 4 byte root, 6 byte vtable, 8 byte object, then the vector.
    offset = 4 + 6 + 8
    <<head::binary-size(^offset), _old::little-32, tail::binary>> = bin
    head <> <<value::little-32>> <> tail
  end

  defp table(fields) do
    vtable_size = 4 + length(fields) * 2
    {body, payloads} = object(fields, vtable_size)
    object_size = byte_size(body)

    vtable =
      <<vtable_size::little-16, object_size::little-16>> <>
        (fields
         |> field_slots()
         |> Enum.map(&<<&1::little-16>>)
         |> IO.iodata_to_binary())

    <<4 + vtable_size::little-32, vtable::binary, body::binary,
      IO.iodata_to_binary(payloads)::binary>>
  end

  defp object(fields, table_pos) do
    payload_at = table_pos + 4 + inline_size(fields)

    {body, payloads, _payload_at} =
      Enum.reduce(fields, {<<table_pos::little-signed-32>>, [], payload_at}, fn field,
                                                                                {body, payloads,
                                                                                 payload_at} ->
        append(field, body, payloads, payload_at, table_pos)
      end)

    {body, payloads}
  end

  defp append({:u8, value}, body, payloads, payload_at, _table_pos) do
    {body <> <<value>>, payloads, payload_at}
  end

  defp append({:bool, true}, body, payloads, payload_at, table_pos) do
    append({:u8, 1}, body, payloads, payload_at, table_pos)
  end

  defp append({:bool, false}, body, payloads, payload_at, table_pos) do
    append({:u8, 0}, body, payloads, payload_at, table_pos)
  end

  defp append({:u16, value}, body, payloads, payload_at, _table_pos) do
    {body <> <<value::little-16>>, payloads, payload_at}
  end

  defp append({:i16, value}, body, payloads, payload_at, _table_pos) do
    {body <> <<value::little-signed-16>>, payloads, payload_at}
  end

  defp append({:u32, value}, body, payloads, payload_at, _table_pos) do
    {body <> <<value::little-32>>, payloads, payload_at}
  end

  defp append({:i32, value}, body, payloads, payload_at, _table_pos) do
    {body <> <<value::little-signed-32>>, payloads, payload_at}
  end

  defp append({:u64, value}, body, payloads, payload_at, _table_pos) do
    {body <> <<value::little-64>>, payloads, payload_at}
  end

  defp append({:string, text}, body, payloads, payload_at, table_pos) do
    append({:bytes, text}, body, payloads, payload_at, table_pos)
  end

  defp append({:bytes, raw}, body, payloads, payload_at, table_pos) do
    payload = <<byte_size(raw)::little-32, raw::binary>>
    pointer(body, payloads, payload_at, table_pos, payload)
  end

  defp append({:u32s, values}, body, payloads, payload_at, table_pos) do
    packed = IO.iodata_to_binary(Enum.map(values, &<<&1::little-32>>))
    pointer(body, payloads, payload_at, table_pos, <<length(values)::little-32, packed::binary>>)
  end

  defp append({:u64s, values}, body, payloads, payload_at, table_pos) do
    packed = IO.iodata_to_binary(Enum.map(values, &<<&1::little-64>>))
    pointer(body, payloads, payload_at, table_pos, <<length(values)::little-32, packed::binary>>)
  end

  defp append({:strings, values}, body, payloads, payload_at, table_pos) do
    entries_at = payload_at + 4
    entries_size = length(values) * 4

    {words, blobs, _at} =
      Enum.reduce(values, {[], [], entries_at + entries_size}, fn text, {words, blobs, at} ->
        relative = at - (entries_at + length(words) * 4)
        payload = <<byte_size(text)::little-32, text::binary>>
        {[<<relative::little-32>> | words], [blobs, payload], at + byte_size(payload)}
      end)

    payload =
      <<length(values)::little-32, IO.iodata_to_binary(Enum.reverse(words))::binary,
        IO.iodata_to_binary(blobs)::binary>>

    pointer(body, payloads, payload_at, table_pos, payload)
  end

  defp append({:table, fields}, body, payloads, payload_at, table_pos) do
    child = child_bytes(fields)
    child_table = payload_at + 4 + length(fields) * 2
    relative = child_table - (table_pos + byte_size(body))
    {body <> <<relative::little-32>>, payloads ++ [child], payload_at + byte_size(child)}
  end

  defp pointer(body, payloads, payload_at, table_pos, payload) do
    relative = payload_at - (table_pos + byte_size(body))
    {body <> <<relative::little-32>>, payloads ++ [payload], payload_at + byte_size(payload)}
  end

  defp child_bytes(fields) do
    vtable_size = 4 + length(fields) * 2
    {body, payloads} = object(fields, vtable_size)
    object_size = byte_size(body)

    vtable =
      <<vtable_size::little-16, object_size::little-16>> <>
        (fields
         |> field_slots()
         |> Enum.map(&<<&1::little-16>>)
         |> IO.iodata_to_binary())

    IO.iodata_to_binary([vtable, body, payloads])
  end

  defp field_slots(fields) do
    {slots, _cursor} =
      Enum.map_reduce(fields, 4, fn field, cursor ->
        {cursor, cursor + inline_width(field)}
      end)

    slots
  end

  defp inline_size(fields),
    do: Enum.reduce(fields, 0, fn field, acc -> acc + inline_width(field) end)

  defp inline_width({:u8, _}), do: 1
  defp inline_width({:bool, _}), do: 1
  defp inline_width({:u16, _}), do: 2
  defp inline_width({:i16, _}), do: 2
  defp inline_width({:u64, _}), do: 8
  defp inline_width(_field), do: 4
end
