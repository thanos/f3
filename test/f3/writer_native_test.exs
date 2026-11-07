defmodule F3.WriterNativeTest do
  use ExUnit.Case, async: false

  @moduletag :native

  test "round trip covers the claimed types, nulls, batches, and compressions" do
    rows = [sample_row(), second_row()]

    for compression <- [:uncompressed, :zstd, :lz4] do
      path = fresh_path()

      assert {:ok, writer} =
               F3.Writer.open(path, schema: sample_schema(), compression: compression)

      assert :ok = F3.Writer.write(writer, [])
      assert :ok = F3.Writer.write(writer, [sample_row(), second_row()])
      assert {:ok, closed} = F3.Writer.close(writer)
      assert {:ok, ^closed} = F3.Writer.close(closed)
      assert {:error, %F3.Error{category: :closed}} = F3.Writer.write(closed, [])
      assert_agrees(path, rows, closed.schema)
    end
  end

  test "an F3.Batch round trips, including an empty batch" do
    path = fresh_path()
    assert {:ok, writer} = F3.Writer.open(path, schema: [id: :int64, name: :utf8])

    empty = %F3.Batch{
      schema: writer.schema,
      num_rows: 0,
      columns: %{
        "id" => %F3.Column{kind: :i64, num_rows: 0, values: <<>>},
        "name" => %F3.Column{kind: :utf8, num_rows: 0, values: []}
      }
    }

    row = %F3.Batch{
      schema: writer.schema,
      num_rows: 1,
      columns: %{
        "id" => %F3.Column{kind: :i64, num_rows: 1, values: <<-3::signed-little-64>>},
        "name" => %F3.Column{kind: :utf8, num_rows: 1, values: ["z"]}
      }
    }

    assert :ok = F3.Writer.write(writer, empty)
    assert :ok = F3.Writer.write(writer, row)
    assert {:ok, _} = F3.Writer.close(writer)
    assert_agrees(path, [%{"id" => -3, "name" => "z"}], nil)
  end

  test "two list batches are readable by this library" do
    path = fresh_path()
    assert {:ok, writer} = F3.Writer.open(path, schema: [tags: {:list, :int32}])
    assert :ok = F3.Writer.write(writer, [%{tags: [1, 2]}])
    assert :ok = F3.Writer.write(writer, [%{tags: [3]}])
    assert {:ok, _} = F3.Writer.close(writer)
    {got, _schema} = read_rows(path)
    assert got == [%{"tags" => [1, 2]}, %{"tags" => [3]}]
  end

  test "two writes past the row group threshold produce two row groups" do
    path = fresh_path()
    assert {:ok, writer} = F3.Writer.open(path, schema: [id: :int64], row_group_rows: 2)
    assert :ok = F3.Writer.write(writer, [%{id: 1}, %{id: 2}])
    assert :ok = F3.Writer.write(writer, [%{id: 3}])
    assert {:ok, _} = F3.Writer.close(writer)

    {:ok, file} = F3.open(path)
    {:ok, metadata} = F3.metadata(file)
    assert Enum.map(metadata.row_groups, & &1.num_rows) == [2, 1]
    {:ok, _} = F3.close(file)
    assert_agrees(path, [%{"id" => 1}, %{"id" => 2}, %{"id" => 3}], nil)
  end

  test "checksums are accepted by the elixir reader and the upstream reader" do
    path = fresh_path()
    assert {:ok, writer} = F3.Writer.open(path, schema: [id: :uint32], checksum: true)
    assert :ok = F3.Writer.write(writer, [%{id: 7}])
    assert {:ok, closed} = F3.Writer.close(writer)
    assert_agrees(path, [%{"id" => 7}], closed.schema, true)
  end

  test "bad rows and a mismatched batch leave no destination" do
    dir = fresh_dir()
    path = Path.join(dir, "out.f3")
    assert {:ok, writer} = F3.Writer.open(path, schema: [id: :int32, name: :utf8])

    assert {:error, %F3.Error{category: :invalid_type}} =
             F3.Writer.write(writer, [%{id: 2_147_483_648, name: "a"}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.write(writer, [%{id: 1, name: <<0xFF>>}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.write(writer, [%{id: 1, name: "a", extra: 1}])

    other = %F3.Schema{fields: [%{name: "id", type: :utf8, nullable: false}]}
    batch = %F3.Batch{schema: other, num_rows: 0, columns: %{}}
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.Writer.write(writer, batch)
    refute File.exists?(path)
    assert {:error, _} = F3.Writer.fail_finish(writer)
    assert File.ls!(dir) == []
  end

  test "a failed finish and a crashed helper leave the destination untouched" do
    dir = fresh_dir()
    kept = Path.join(dir, "kept.f3")
    File.write!(kept, "keep")
    assert {:ok, writer} = F3.Writer.open(kept, schema: [id: :int64])
    assert :ok = F3.Writer.write(writer, [%{id: 1}])
    assert {:error, %F3.Error{category: :io}} = F3.Writer.fail_finish(writer)
    assert File.read!(kept) == "keep"
    assert temps(dir) == []

    missing = Path.join(dir, "missing.f3")
    assert {:ok, crashed} = F3.Writer.open(missing, schema: [id: :int64])
    assert :ok = F3.Writer.write(crashed, [%{id: 1}])
    Port.close(crashed.port)
    assert {:error, %F3.Error{category: :io}} = F3.Writer.close(crashed)
    refute File.exists?(missing)
    assert temps(dir) == []
  end

  test "two writers can be open at once" do
    left = fresh_path()
    right = fresh_path()
    assert {:ok, a} = F3.Writer.open(left, schema: [id: :uint8])
    assert {:ok, b} = F3.Writer.open(right, schema: [id: :uint8])
    assert :ok = F3.Writer.write(a, [%{id: 1}])
    assert :ok = F3.Writer.write(b, [%{id: 2}])
    assert {:ok, _} = F3.Writer.close(a)
    assert {:ok, _} = F3.Writer.close(b)
    assert_agrees(left, [%{"id" => 1}], nil)
    assert_agrees(right, [%{"id" => 2}], nil)
  end

  test "the committed small fixture still reads" do
    {:ok, file} = F3.open("test/fixtures/small.f3")
    {:ok, batches} = F3.read(file)
    rows = flatten(batches)
    {:ok, _} = F3.close(file)
    assert length(rows) == 3
    assert hd(rows)["symbol"] == "AAPL"
  end

  defp sample_schema do
    [
      i64: :int64,
      i32: :int32,
      u64: :uint64,
      u32: :uint32,
      u16: :uint16,
      u8: :uint8,
      f64: :float64,
      f32: :float32,
      flag: :bool,
      name: :utf8,
      maybe: {:int64, null: true},
      tags: {:list, {:int32, null: true}},
      nested: {:struct, [code: :uint8, label: {:utf8, null: true}]}
    ]
  end

  defp sample_row do
    %{
      i64: -1,
      i32: -2,
      u64: Bitwise.bsl(1, 40),
      u32: 4,
      u16: 5,
      u8: 6,
      f64: 1.5,
      f32: 2.5,
      flag: true,
      name: "π",
      maybe: nil,
      tags: [1, nil, 2],
      nested: %{code: 7, label: nil}
    }
  end

  defp second_row do
    %{
      "i64" => 9,
      "i32" => 8,
      "u64" => 0,
      "u32" => 1,
      "u16" => 2,
      "u8" => 3,
      "f64" => -1.5,
      "f32" => 0.5,
      "flag" => false,
      "name" => "",
      "maybe" => 8,
      "tags" => [],
      "nested" => %{"code" => 9, "label" => "x"}
    }
  end

  defp stringify(row) when is_map(row) do
    Map.new(row, fn
      {key, value} when is_atom(key) -> {Atom.to_string(key), stringify(value)}
      {key, value} -> {key, stringify(value)}
    end)
  end

  defp stringify(values) when is_list(values), do: Enum.map(values, &stringify/1)
  defp stringify(value), do: value

  defp assert_agrees(path, rows, schema, verify? \\ false) do
    {got, read_schema} = read_rows(path)
    assert got == Enum.map(rows, &stringify/1)
    if schema, do: assert(read_schema.fields == schema.fields)
    args = if verify?, do: ["read", "--verify", path], else: ["read", path]
    {json, 0} = System.cmd(F3.Writer.executable(), args)
    upstream = json |> String.trim() |> :json.decode() |> nulls_to_nil()
    assert upstream == Enum.map(rows, &stringify/1)
  end

  defp read_rows(path) do
    {:ok, file} = F3.open(path)
    {:ok, batches} = F3.read(file)
    {:ok, schema} = F3.schema(file)
    {:ok, _} = F3.close(file)
    {flatten(batches), schema}
  end

  defp flatten(batches) do
    Enum.flat_map(batches, fn batch ->
      {:ok, rows} = F3.Batch.to_rows(batch)
      rows
    end)
  end

  defp nulls_to_nil(:null), do: nil

  defp nulls_to_nil(value) when is_map(value),
    do: Map.new(value, fn {key, nested} -> {key, nulls_to_nil(nested)} end)

  defp nulls_to_nil(value) when is_list(value), do: Enum.map(value, &nulls_to_nil/1)
  defp nulls_to_nil(value), do: value

  defp fresh_dir do
    dir = Path.join(System.tmp_dir!(), "f3-writer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp fresh_path, do: Path.join(fresh_dir(), "out.f3")
  defp temps(dir), do: Path.wildcard(Path.join(dir, "*.f3tmp"))
end
