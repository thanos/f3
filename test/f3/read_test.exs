defmodule F3.ReadTest do
  use ExUnit.Case, async: false

  setup do
    Application.put_env(:f3, :decoder, F3.Decoder.Mock)
    on_exit(fn -> Application.delete_env(:f3, :decoder) end)
    :ok
  end

  test "projects columns, slices batches, and materializes rows" do
    stub_small()
    {:ok, file} = F3.open("test/fixtures/small.f3")

    assert {:ok, batches} = F3.read(file, batch_size: 2, columns: ["symbol", "trade_id"])
    assert length(batches) == 2
    assert hd(batches).num_rows == 2
    assert Enum.map(hd(batches).schema.fields, & &1.name) == ["symbol", "trade_id"]

    assert {:ok, rows} = F3.Batch.to_rows(hd(batches))

    assert rows == [
             %{"symbol" => "AAPL", "trade_id" => 1},
             %{"symbol" => "MSFT", "trade_id" => 2}
           ]
  end

  test "an unknown column, a bad row group, and a bad batch size are errors" do
    stub_small()
    {:ok, file} = F3.open("test/fixtures/small.f3")

    assert {:error, %F3.Error{category: :invalid_projection}} =
             F3.read(file, columns: ["missing"])

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, row_groups: [3])
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, row_groups: [-1])
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, batch_size: 0)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, limit: 1)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, columns: [:symbol])
  end

  test "read after close fails and two handles can be open together" do
    stub_small()
    {:ok, first} = F3.open("test/fixtures/small.f3")
    {:ok, second} = F3.open("test/fixtures/small.f3")
    assert {:ok, [%F3.Batch{num_rows: 3}]} = F3.read(first)
    assert {:ok, [%F3.Batch{num_rows: 3}]} = F3.read(second)
    {:ok, closed} = F3.close(first)
    assert {:error, %F3.Error{category: :closed}} = F3.read(closed)
    assert {:error, %F3.Error{category: :closed}} = F3.stream(closed)
  end

  test "a stream does not pread until the first pull and take stops at the first row group" do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, :i64 ->
      n = Agent.get_and_update(calls, fn i -> {i, i + 1} end)
      if n == 0, do: column(:i64, [1, 2]), else: column(:i64, [3])
    end)

    file = tapped("test/fixtures/multi_row_group.f3", agent)
    assert {:ok, stream} = F3.stream(file, batch_size: 10)
    assert Agent.get(agent, & &1) == []

    assert [%F3.Batch{num_rows: 2}] = Enum.take(stream, 1)
    assert Agent.get(calls, & &1) == 1
    refute Enum.any?(Agent.get(agent, & &1), fn {offset, _len} -> offset == 1664 end)
  end

  test "a bad projection is thrown on the first stream pull" do
    stub_small()
    {:ok, file} = F3.open("test/fixtures/small.f3")
    assert {:ok, stream} = F3.stream(file, columns: ["nope"])

    assert {:f3, %F3.Error{category: :invalid_projection}} =
             catch_throw(Enum.to_list(stream))
  end

  test "a corrupt encoding unit is a tagged error" do
    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, _type ->
      {:error, F3.Error.corrupt(:decode, "bad unit")}
    end)

    {:ok, file} = F3.open("test/fixtures/small.f3")
    assert {:error, %F3.Error{category: :corrupt, message: "bad unit"}} = F3.read(file)
  end

  test "wasm stays off and a shared dictionary is refused" do
    unit = %{encoding: :custom_wasm, compression: :uncompressed, wasm_id: 0}

    plan = %{
      versions: [
        %{encoding: :custom_wasm, version: %{major: 1, minor: 0, patch: 0}},
        %{encoding: :cascade, version: %{major: 0, minor: 21, patch: 0}}
      ],
      wasm: :off,
      extensions: nil,
      operation: :read
    }

    assert {:error, %F3.Error{category: :unsupported_encoding, message: message}} =
             F3.Dispatch.choose(unit, plan)

    assert message =~ "CUSTOM_WASM"
    assert {:ok, :wasm} = F3.Dispatch.choose(unit, %{plan | wasm: :sandbox})

    assert {:ok, :native} =
             F3.Dispatch.choose(
               %{encoding: :cascade, compression: :uncompressed, wasm_id: nil},
               plan
             )

    assert {:error, %F3.Error{category: :unsupported_encoding}} =
             F3.Reader.reject_chunk(%{dictionary: {:shared, 2}, encunits: []})
  end

  test "a default read does not pread the wasm section" do
    stub_small()
    {:ok, file} = F3.open("test/fixtures/small.f3")
    {:ok, meta} = F3.metadata(file)
    section = Enum.find(meta.optional_sections, &(&1.name == "WASMBinaries"))
    {:ok, agent} = Agent.start_link(fn -> [] end)
    tapped = tapped("test/fixtures/small.f3", agent)

    assert {:ok, [%F3.Batch{num_rows: 3}]} = F3.read(tapped)
    refute section_hit?(Agent.get(agent, & &1), section)

    {:ok, agent} = Agent.start_link(fn -> [] end)
    tapped = tapped("test/fixtures/small.f3", agent)
    assert {:ok, stream} = F3.stream(tapped)
    assert [%F3.Batch{num_rows: 3}] = Enum.to_list(stream)
    refute section_hit?(Agent.get(agent, & &1), section)

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, wasm: :on)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, extensions: :nope)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.read(file, wasm_module_bytes: 16 * 1024 * 1024 + 1)
  end

  test "nested struct and list columns stitch to the manifest rows" do
    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, type ->
      case type do
        :bool ->
          column(:bool, [1, 1, 1, 1])

        :i32 ->
          n = Process.get(:i32, 0)
          Process.put(:i32, n + 1)

          if n == 0 do
            column(:i32, [1, 2, 0, 4], <<1, 1, 0, 1>>)
          else
            column(:i32, [1, 2, 3, 4])
          end

        :utf8 ->
          column(:utf8, ["a", "b", "", "d"], <<1, 1, 0, 1>>)

        :list32 ->
          column(:list32, [0, 2, 3, 3, 4])
      end
    end)

    {:ok, file} = F3.open("test/fixtures/nested.f3")
    assert {:ok, [first, second]} = F3.read(file, batch_size: 2)
    assert {:ok, rows} = F3.Batch.to_rows(first)
    assert {:ok, rest} = F3.Batch.to_rows(second)

    assert rows == [
             %{"trade" => %{"b" => 1, "c" => "a"}, "nums" => [1, 2]},
             %{"trade" => %{"b" => 2, "c" => "b"}, "nums" => [3]}
           ]

    assert rest == [
             %{"trade" => %{"b" => nil, "c" => nil}, "nums" => []},
             %{"trade" => %{"b" => 4, "c" => "d"}, "nums" => [4]}
           ]
  end

  test "a local dictionary gathers indexes into values" do
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, type ->
      case type do
        :i64 ->
          column(:i64, [1, 2, 3, 4])

        :utf8 ->
          column(:utf8, ["AAPL", "MSFT"])

        :integer ->
          n = Agent.get_and_update(calls, fn i -> {i, i + 1} end)
          if n == 0, do: column(:u8, [0, 1, 2, 3]), else: column(:u8, [0, 0, 1, 0])
      end
    end)

    {:ok, file} = F3.open("test/fixtures/dictionary.f3")
    assert {:ok, [batch]} = F3.read(file)
    assert {:ok, rows} = F3.Batch.to_rows(batch)

    assert rows == [
             %{"trade_id" => 1, "symbol" => "AAPL"},
             %{"trade_id" => 2, "symbol" => "AAPL"},
             %{"trade_id" => 3, "symbol" => "MSFT"},
             %{"trade_id" => 4, "symbol" => "AAPL"}
           ]
  end

  test "an empty projection does not decode and still reports the row count" do
    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, _type ->
      flunk("decoder should not be called")
    end)

    {:ok, file} = F3.open("test/fixtures/small.f3")
    assert {:ok, [%F3.Batch{num_rows: 3, columns: columns}]} = F3.read(file, columns: [])
    assert columns == %{}
    assert {:ok, [%{}, %{}, %{}]} = F3.Batch.to_rows(hd(elem(F3.read(file, columns: []), 1)))
  end

  test "checksum mismatch is reported and a missing checksum is skipped" do
    assert :ok = F3.Checksum.verify("hello", nil)
    assert :ok = F3.Checksum.verify("hello", F3.Checksum.xxh64("hello"))
    assert {:error, %F3.Error{category: :checksum}} = F3.Checksum.verify("hello", 1)
    assert F3.Checksum.xxh64("") == 0xEF46DB3751D8E999
    assert F3.Checksum.xxh64("a") == 15_154_266_338_359_012_955
    assert F3.Checksum.xxh64("abcd") == 15_997_673_941_747_208_908
    assert F3.Checksum.xxh64("01234567") == 16_481_523_876_683_619_647
    assert F3.Checksum.xxh64("0123456789abcdef0123456789abcdef") == 7_217_744_722_875_508_421
    assert F3.Checksum.xxh64("0123456789abcdef0123456789abcdef!") == 10_015_993_316_326_139_774
    assert F3.Checksum.xxh64("0123456789abcdef0123456789abcd") == 16_664_237_951_995_880_769

    assert F3.Checksum.xxh64("0123456789abcdef0123456789abcdefHELLO") ==
             15_090_834_720_473_607_110
  end

  test "the logical tree must agree with the schema" do
    fields = [%{name: "a", type: {:int, 64, true}, nullable: false}]
    assert F3.Logical.matches?(%{id: :struct, children: [%{id: :flat, children: []}]}, fields)
    refute F3.Logical.matches?(%{id: :struct, children: []}, fields)

    list_field = %{
      name: "nums",
      type: {:list, %{name: "item", type: {:int, 32, true}, nullable: false}},
      nullable: true
    }

    assert F3.Logical.matches?(
             %{id: :struct, children: [%{id: :list, children: [%{id: :flat, children: []}]}]},
             [list_field]
           )

    refute F3.Logical.matches?(
             %{id: :struct, children: [%{id: :flat, children: []}]},
             [list_field]
           )

    skipped = [
      %{
        name: "trade",
        type: {:struct, [%{name: "b", type: {:int, 64, true}, nullable: true}]},
        nullable: true
      },
      %{name: "c", type: {:int, 32, false}, nullable: false}
    ]

    assert {:ok, [{2, :u32}]} = F3.Logical.needed(skipped, ["c"])

    for type <- [
          :binary,
          :null,
          {:int, 16, true},
          {:int, 8, true},
          {:float, :half},
          {:unsupported, 7},
          :date
        ] do
      assert {:error, %F3.Error{category: :unsupported_encoding}} =
               F3.Logical.needed([%{name: "a", type: type, nullable: false}], ["a"])
    end

    unsigned = [
      %{name: "u64", type: {:int, 64, false}, nullable: false},
      %{name: "u16", type: {:int, 16, false}, nullable: false},
      %{name: "u8", type: {:int, 8, false}, nullable: false},
      %{name: "f", type: {:float, :single}, nullable: false},
      %{name: "flag", type: :bool, nullable: false}
    ]

    assert {:ok, pairs} = F3.Logical.needed(unsigned, Enum.map(unsigned, & &1.name))
    assert pairs == [{0, :u64}, {1, :u16}, {2, :u8}, {3, :f32}, {4, :bool}]

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Logical.assemble(
               [%{name: "a", type: {:int, 64, true}, nullable: false}],
               ["a"],
               %{}
             )

    {:ok, wrong} = F3.Column.from_native(:i32, 1, <<1::signed-little-32>>, nil)

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Logical.assemble(
               [%{name: "a", type: {:int, 64, true}, nullable: false}],
               ["a"],
               %{0 => wrong}
             )

    {:ok, offsets} = F3.Column.from_native(:i32, 1, <<1::signed-little-32>>, nil)

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Logical.assemble([list_field], ["nums"], %{0 => offsets})
  end

  test "row group order, bad options, a short chunk, and a stream that finishes" do
    stub_small()
    assert F3.Reader.default_batch_size() == 8192
    {:ok, file} = F3.open("test/fixtures/small.f3")
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(:nope)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, :nope)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.stream(file, :nope)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, columns: "symbol")
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, row_groups: 0)

    assert {:ok, [%F3.Batch{num_rows: 3}]} = F3.read(file, row_groups: [0])
    assert {:ok, stream} = F3.stream(file)
    assert [%F3.Batch{num_rows: 3}] = Enum.to_list(stream)

    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, :i64 ->
      column(:i64, [1])
    end)

    assert {:error, %F3.Error{category: :corrupt}} = F3.read(file, columns: ["trade_id"])

    assert {:error, %F3.Error{category: :unsupported_encoding}} =
             F3.Reader.reject_chunk(%{
               dictionary: :none,
               encunits: [%{encoding: :cascade, compression: :gzip}]
             })

    assert {:error, %F3.Error{category: :truncated}} =
             F3.read(short_source(), columns: ["trade_id"])

    assert {:error, %F3.Error{category: :io}} = F3.read(io_source(), columns: ["trade_id"])

    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, :i64 ->
      n = Agent.get_and_update(calls, fn i -> {i, i + 1} end)
      if n == 0, do: column(:i64, [3]), else: column(:i64, [1, 2])
    end)

    {:ok, grouped} = F3.open("test/fixtures/multi_row_group.f3")
    assert {:ok, [second, first]} = F3.read(grouped, row_groups: [1, 0], columns: ["trade_id"])
    assert second.num_rows == 1
    assert first.num_rows == 2

    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, _type ->
      {:error, F3.Error.corrupt(:decode, "bad unit")}
    end)

    {:ok, broken} = F3.open("test/fixtures/small.f3")
    assert {:ok, stream} = F3.stream(broken, columns: ["trade_id"])
    assert {:f3, %F3.Error{category: :corrupt}} = catch_throw(Enum.to_list(stream))
  end

  test "list columns rebase offsets when concatenated" do
    {:ok, left_child} = column(:i32, [1, 2])
    {:ok, right_child} = column(:i32, [3])
    {:ok, left} = F3.Column.list(elem(column(:list32, [0, 2]), 1), left_child)
    {:ok, right} = F3.Column.list(elem(column(:list32, [0, 1]), 1), right_child)
    assert {:ok, joined} = F3.Column.concat(left, right)
    assert F3.Column.value(joined, 0) == [1, 2]
    assert F3.Column.value(joined, 1) == [3]
    sliced = F3.Column.slice(joined, 1, 1)
    assert F3.Column.value(sliced, 0) == [3]
  end

  defp stub_small do
    Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, type ->
      case type do
        :i64 -> column(:i64, [1, 2, 3])
        :utf8 -> column(:utf8, ["AAPL", "MSFT", "GOOG"])
        :f64 -> column(:f64, [123.5, 234.0, 345.25])
      end
    end)
  end

  defp column(kind, values, validity \\ nil)

  defp column(:utf8, values, validity) do
    F3.Column.from_native(:utf8, length(values), values, validity)
  end

  defp column(:list32, offsets, _validity) do
    bytes = Enum.reduce(offsets, <<>>, fn n, acc -> acc <> <<n::signed-little-32>> end)
    F3.Column.from_native(:list32, length(offsets) - 1, bytes, nil)
  end

  defp column(:bool, values, _validity) do
    F3.Column.from_native(:bool, length(values), :binary.list_to_bin(values), nil)
  end

  defp column(:f64, values, _validity) do
    bytes = Enum.reduce(values, <<>>, fn n, acc -> acc <> <<n::float-little-64>> end)
    F3.Column.from_native(:f64, length(values), bytes, nil)
  end

  defp column(kind, values, validity) do
    width =
      %{i64: 64, i32: 32, u64: 64, u32: 32, u16: 16, u8: 8}
      |> Map.fetch!(kind)

    bytes =
      Enum.reduce(values, <<>>, fn n, acc ->
        acc <> <<n::unsigned-little-size(width)>>
      end)

    F3.Column.from_native(kind, length(values), bytes, validity)
  end

  defp short_source do
    altered("test/fixtures/small.f3", fn offset, length, memory ->
      if offset == 0 and length > 1000 do
        {:ok, <<0>>}
      else
        F3.IO.Memory.pread(memory, offset, length)
      end
    end)
  end

  defp io_source do
    altered("test/fixtures/small.f3", fn offset, length, memory ->
      if offset == 0 and length > 1000 do
        {:error, F3.Error.io(:pread, :eio)}
      else
        F3.IO.Memory.pread(memory, offset, length)
      end
    end)
  end

  defp altered(path, fun) do
    {:ok, memory} = File.read!(path) |> F3.IO.Memory.open()

    %F3.File{
      source_module: __MODULE__.Altered,
      source_state: {fun, memory},
      origin: :memory
    }
  end

  defp section_hit?(reads, section) do
    Enum.any?(reads, fn {offset, length} ->
      offset < section.offset + section.size and offset + length > section.offset
    end)
  end

  defp tapped(path, agent) do
    {:ok, memory} = File.read!(path) |> F3.IO.Memory.open()

    %F3.File{
      source_module: __MODULE__.Tap,
      source_state: {agent, memory},
      origin: :memory
    }
  end
end

defmodule F3.ReadTest.Altered do
  @behaviour F3.IO.Source

  def size({_fun, memory}), do: F3.IO.Memory.size(memory)

  def pread({fun, memory}, offset, length), do: fun.(offset, length, memory)

  def close({fun, memory}) do
    {:ok, closed} = F3.IO.Memory.close(memory)
    {:ok, {fun, closed}}
  end
end

defmodule F3.ReadTest.Tap do
  @behaviour F3.IO.Source

  def size({_agent, memory}), do: F3.IO.Memory.size(memory)

  def pread({agent, memory}, offset, length) do
    Agent.update(agent, &[{offset, length} | &1])
    F3.IO.Memory.pread(memory, offset, length)
  end

  def close({agent, memory}) do
    {:ok, closed} = F3.IO.Memory.close(memory)
    {:ok, {agent, closed}}
  end
end
