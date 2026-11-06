defmodule F3.ColumnTest do
  use ExUnit.Case, async: true

  test "native terms with the wrong shape are corrupt" do
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.from_native(:nope, 1, <<0>>, nil)
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.from_native(:i64, -1, <<>>, nil)
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.from_native(:i64, 1, <<1>>, nil)

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Column.from_native(:i64, 1, <<0::64>>, <<2>>)

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Column.from_native(:i64, 1, <<0::64>>, <<0, 1>>)

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Column.from_native(:utf8, 1, ["ok", "x"], nil)

    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.from_native(:utf8, 1, [:no], nil)

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Column.from_native(:list32, 1, <<0::32>>, nil)

    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.from_native(:i64, 1, [1], nil)
  end

  test "empty columns, widths, and null values" do
    assert F3.Column.empty(:utf8).values == []
    assert F3.Column.empty(:i64).num_rows == 0
    assert F3.Column.empty(:list32).num_rows == 0
    assert F3.Column.empty(:list64).num_rows == 0
    assert F3.Column.empty(:bool).values == <<>>

    {:ok, flags} = F3.Column.from_native(:bool, 2, <<1, 0>>, <<1, 0>>)
    assert F3.Column.value(flags, 0) == true
    assert F3.Column.value(flags, 1) == nil

    {:ok, price} = F3.Column.from_native(:f32, 1, <<1.5::float-little-32>>, nil)
    assert F3.Column.value(price, 0) == 1.5

    for {kind, width, value} <- [{:u64, 64, 9}, {:u32, 32, 8}, {:u16, 16, 7}, {:i32, 32, 6}] do
      bytes = <<value::unsigned-little-size(width)>>
      {:ok, column} = F3.Column.from_native(kind, 1, bytes, <<0>>)
      assert F3.Column.value(column, 0) == nil
    end
  end

  test "structs and lists reject a bad shape and keep nulls" do
    {:ok, child} = F3.Column.from_native(:i32, 1, <<4::signed-little-32>>, nil)
    {:ok, flags} = F3.Column.from_native(:bool, 2, <<1, 0>>, nil)
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.struct(["b"], flags, [child])
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.struct(["b"], child, [child])

    {:ok, one} = F3.Column.from_native(:i64, 1, <<1::signed-little-64>>, nil)
    {:ok, flags} = F3.Column.from_native(:bool, 1, <<0>>, nil)
    assert {:ok, column} = F3.Column.struct(["b"], flags, [one])
    assert F3.Column.value(column, 0) == nil

    {:ok, offsets} =
      F3.Column.from_native(:list64, 1, <<0::signed-little-64, 1::signed-little-64>>, nil)

    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.list(one, child)

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Column.list(offsets, F3.Column.empty(:i64))

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Column.from_native(
               :list32,
               1,
               <<0::signed-little-32, 0::signed-little-32, 0::signed-little-32>>,
               nil
             )

    short = %F3.Column{kind: :list32, num_rows: 1, values: <<0::signed-little-32>>}
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.list(short, child)
  end

  test "concatenation, slicing, and dictionary gather cover the other kinds" do
    {:ok, left} = F3.Column.from_native(:utf8, 1, ["a"], nil)
    {:ok, right} = F3.Column.from_native(:utf8, 1, ["b"], <<0>>)
    assert {:ok, joined} = F3.Column.concat(left, right)
    assert F3.Column.value(F3.Column.slice(joined, 0, 1), 0) == "a"
    assert F3.Column.value(joined, 1) == nil

    {:ok, i64} = F3.Column.from_native(:i64, 1, <<1::signed-little-64>>, nil)
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.concat(left, i64)
    refute F3.Column.matches?(left, :i64)
    assert F3.Column.matches?(i64, :integer)

    {:ok, flags} = F3.Column.from_native(:bool, 1, <<1>>, nil)
    {:ok, nested} = F3.Column.struct(["b"], flags, [i64])
    {:ok, more_flags} = F3.Column.from_native(:bool, 1, <<1>>, nil)
    {:ok, more} = F3.Column.from_native(:i64, 1, <<2::signed-little-64>>, nil)
    {:ok, nested_right} = F3.Column.struct(["b"], more_flags, [more])
    assert {:ok, structs} = F3.Column.concat(nested, nested_right)
    assert F3.Column.value(F3.Column.slice(structs, 1, 1), 0) == %{"b" => 2}

    {:ok, dict} = F3.Column.from_native(:bool, 2, <<1, 0>>, nil)
    {:ok, indexes} = F3.Column.from_native(:u16, 2, <<0::16, 0::16>>, <<1, 0>>)
    assert {:ok, gathered} = F3.Column.gather(dict, indexes)
    assert F3.Column.value(gathered, 0) == true
    assert F3.Column.value(gathered, 1) == nil

    {:ok, wide} = F3.Column.from_native(:u32, 1, <<4::unsigned-little-32>>, nil)
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.gather(dict, wide)
    assert {:error, %F3.Error{category: :corrupt}} = F3.Column.gather(dict, left)

    {:ok, words} = F3.Column.from_native(:utf8, 1, ["A"], nil)
    {:ok, picked} = F3.Column.gather(words, F3.Column.empty(:u8))
    assert picked.num_rows == 0

    {:ok, child} = F3.Column.from_native(:i32, 1, <<9::signed-little-32>>, nil)

    {:ok, list_left} =
      F3.Column.list(
        elem(
          F3.Column.from_native(:list64, 1, <<0::signed-little-64, 1::signed-little-64>>, <<0>>),
          1
        ),
        child
      )

    {:ok, list_right} =
      F3.Column.list(
        elem(
          F3.Column.from_native(:list64, 1, <<0::signed-little-64, 0::signed-little-64>>, nil),
          1
        ),
        F3.Column.empty(:i32)
      )

    assert {:ok, lists} = F3.Column.concat(list_left, list_right)
    assert F3.Column.value(lists, 0) == nil
    assert F3.Column.value(F3.Column.slice(lists, 1, 1), 0) == []
  end

  test "a batch without a schema cannot materialize rows" do
    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Batch.to_rows(%F3.Batch{num_rows: 1, schema: nil, columns: %{}})
  end

  test "the native decoder is unavailable unless the NIF was compiled" do
    assert {:error, :native_unavailable} = F3.Native.decode_encunit(<<>>, :uncompressed, :i64)

    assert {:error, %F3.Error{category: :native_unavailable}} =
             F3.Native.apply_decode(<<>>, :zstd, :utf8)

    assert {:error, %F3.Error{category: :native_unavailable}} = F3.Native.require_decoder(:read)

    assert {:error, %F3.Error{category: :native_unavailable}} =
             F3.Native.apply_wasm(<<>>, <<>>, :uncompressed, :i64, 1, :read)

    assert :ok = F3.Native.clear_wasm_cache()
    assert :ok = F3.Native.invalidate_wasm(<<>>)
    assert {:error, :native_unavailable} = F3.Native.wasm_sample("ok_i64")

    assert {:error, :native_unavailable} =
             F3.Native.decode_wasm(<<>>, <<>>, :uncompressed, :i64, 1)

    assert {:error, %F3.Error{category: :native_unavailable}} =
             F3.Decoder.Native.decode(<<>>, :lz4, :i32)

    refute F3.Native.available?()
  end
end
