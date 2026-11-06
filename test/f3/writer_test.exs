defmodule F3.WriterTest do
  use ExUnit.Case, async: false

  test "rejected options and types create no file" do
    dir = fresh_dir()
    path = Path.join(dir, "out.f3")

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.Writer.open(path)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.Writer.open(path, wasm: true)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.open(path, schema: [id: :int64], compression: :snappy)

    assert {:error, %F3.Error{category: :invalid_type}} =
             F3.Writer.open(path, schema: [blob: :binary])

    assert {:error, %F3.Error{category: :invalid_type}} =
             F3.Writer.open(path, schema: [n: :int8])

    assert {:error, %F3.Error{category: :resource_limit}} =
             F3.Writer.open(path, schema: [id: :int64], iounit_bytes: 64 * 1024 * 1024 + 1)

    assert File.ls!(dir) == []
  end

  test "a valid open without the helper creates nothing" do
    dir = fresh_dir()
    path = Path.join(dir, "out.f3")
    schema = [trade_id: :int64, symbol: :utf8, price: {:float64, null: true}]

    if native_build?() do
      assert {:ok, writer} = F3.Writer.open(path, schema: schema)
      assert {:ok, closed} = F3.Writer.close(writer)
      assert {:ok, _} = F3.Writer.close(closed)
      assert File.exists?(path)
    else
      assert {:error, %F3.Error{category: :not_implemented}} =
               F3.Writer.open(path, schema: schema)

      assert File.ls!(dir) == []
    end
  end

  test "row encoding covers the claimed types without starting a helper" do
    rows = [
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
        tags: [1, nil],
        nested: %{code: 7, label: nil}
      }
    ]

    assert {:ok, frame} = F3.Writer.encode(sample_schema(), rows)
    assert :binary.match(frame, <<2, 1, 0, 0, 0>>) != :nomatch

    assert {:ok, empty} = F3.Writer.encode(sample_schema(), [])
    assert :binary.match(empty, <<2, 0, 0, 0, 0>>) != :nomatch

    assert {:ok, _} =
             F3.Writer.encode(
               [id: :int64, name: :utf8],
               [%{"id" => 1, "name" => "a"}]
             )

    assert {:ok, _} =
             F3.Writer.encode(
               [
                 box:
                   {{:struct,
                     [
                       flag: :bool,
                       label: :utf8,
                       price: :float32,
                       items: {:list, :int32},
                       inner: {:struct, [n: :int32]}
                     ]}, null: true},
                 items: {{:list, :int32}, null: true},
                 price: {:float64, null: true},
                 flag: :bool
               ],
               [%{box: nil, items: nil, price: nil, flag: false}]
             )

    batch = %F3.Batch{
      schema: batch_fields(),
      num_rows: 1,
      columns: %{
        "id" => %F3.Column{kind: :i64, num_rows: 1, values: <<-3::signed-little-64>>},
        "name" => %F3.Column{kind: :utf8, num_rows: 1, values: ["z"], validity: <<1>>},
        "tags" => %F3.Column{
          kind: :list32,
          num_rows: 1,
          values: <<0::signed-little-32, 1::signed-little-32>>,
          child: %F3.Column{kind: :i32, num_rows: 1, values: <<9::signed-little-32>>}
        },
        "nested" => %F3.Column{
          kind: :struct,
          num_rows: 1,
          values: <<>>,
          children: [
            %F3.Column{kind: :u8, num_rows: 1, values: <<7>>},
            %F3.Column{kind: :utf8, num_rows: 1, values: ["x"]}
          ]
        }
      }
    }

    assert {:ok, batch_frame} = F3.Writer.encode(batch_schema(), batch)
    assert :binary.match(batch_frame, <<2, 1, 0, 0, 0>>) != :nomatch

    assert {:ok, _} = F3.Writer.encode([id: :int64, maybe: {:int64, null: true}], [%{id: 1}])
  end

  test "row checks fail before a file exists" do
    schema = [id: :int32, name: :utf8, tags: {:list, :int32}, nested: {:struct, [code: :uint8]}]

    assert {:error, %F3.Error{category: :invalid_type}} =
             F3.Writer.encode(schema, [
               %{id: 2_147_483_648, name: "a", tags: [], nested: %{code: 1}}
             ])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [%{id: 1, name: <<0xFF>>, tags: [], nested: %{code: 1}}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [
               %{id: 1, name: "a", tags: [], nested: %{code: 1}, extra: 1}
             ])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [%{name: "a", tags: [], nested: %{code: 1}}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [%{id: nil, name: "a", tags: [], nested: %{code: 1}}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [%{id: 1, name: "a", tags: nil, nested: %{code: 1}}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [%{id: 1, name: "a", tags: [nil], nested: %{code: 1}}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [%{id: 1, name: "a", tags: :nope, nested: %{code: 1}}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [%{id: 1, name: "a", tags: [], nested: :nope}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, ["row"])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, [%{id: 1, name: 1, tags: [], nested: %{code: 1}}])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode([id: :int64], %F3.Batch{num_rows: 1, columns: %{}})

    other = %F3.Schema{fields: [%{name: "id", type: :utf8, nullable: false}]}

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode(schema, %F3.Batch{schema: other, num_rows: 0, columns: %{}})

    mismatch = %F3.Column{kind: :utf8, num_rows: 1, values: ["a"]}

    assert {:error, %F3.Error{category: :invalid_type}} =
             F3.Writer.encode([id: :int64], %F3.Batch{
               schema: id_schema(),
               num_rows: 1,
               columns: %{"id" => mismatch}
             })

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode([id: :int64], %F3.Batch{
               schema: id_schema(),
               num_rows: 2,
               columns: %{"id" => %F3.Column{kind: :i64, num_rows: 1, values: <<0::64>>}}
             })

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode([id: :int64], %F3.Batch{
               schema: id_schema(),
               num_rows: 1,
               columns: %{}
             })

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.Writer.open(:not_a_path, [])
    assert {:error, %F3.Error{category: :not_implemented}} = F3.Writer.write(%{}, [])
    assert {:error, %F3.Error{category: :not_implemented}} = F3.Writer.close(:writer)
    assert is_binary(F3.Writer.executable())

    closed = %F3.Writer{
      port: nil,
      schema: id_schema(),
      path: "unused.f3",
      temp: nil,
      closed: true
    }

    assert {:error, %F3.Error{category: :closed}} = F3.Writer.write(closed, [])
    assert {:ok, ^closed} = F3.Writer.close(closed)

    idle = %{closed | closed: false}
    assert :ok = F3.Writer.write(idle, [])
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.Writer.write(idle, :nope)

    assert {:error, %F3.Error{category: :invalid_type}} =
             F3.Writer.open("out.f3",
               schema: %F3.Schema{fields: [%{name: "n", type: {:int, 8, true}, nullable: false}]}
             )

    assert {:error, %F3.Error{category: :invalid_type}} =
             F3.Writer.open("out.f3", schema: [n: 1])

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.open("out.f3", schema: [id: :int64], iounit_bytes: 0)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.open("out.f3", schema: [id: :int64], row_group_rows: 0)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.open("out.f3", schema: [id: :int64], checksum: :yes)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Writer.encode([id: :int64], [%{1 => 1, id: 1}])

    assert %F3.Error{category: :io} = F3.Writer.explain_helper("err write finish failed")

    assert %F3.Error{category: :resource_limit} =
             F3.Writer.explain_helper("err write resource limit")

    assert %F3.Error{category: :io} = F3.Writer.explain_helper("err write batch")
  end

  test "a missing directory is io and creates nothing" do
    missing =
      Path.join(System.tmp_dir!(), "f3-missing-#{System.unique_integer([:positive])}/out.f3")

    assert {:error, %F3.Error{category: :io}} = F3.Writer.open(missing, schema: [id: :int64])
    refute File.exists?(Path.dirname(missing))
  end

  defp native_build?, do: File.read("native/f3_native/.f3_build_native") == {:ok, "1"}

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

  defp batch_schema do
    [
      id: :int64,
      name: :utf8,
      tags: {:list, :int32},
      nested: {:struct, [code: :uint8, label: :utf8]}
    ]
  end

  defp batch_fields do
    %F3.Schema{
      fields: [
        %{name: "id", type: {:int, 64, true}, nullable: false},
        %{name: "name", type: :utf8, nullable: false},
        %{
          name: "tags",
          type: {:list, %{name: "item", type: {:int, 32, true}, nullable: false}},
          nullable: false
        },
        %{
          name: "nested",
          type:
            {:struct,
             [
               %{name: "code", type: {:int, 8, false}, nullable: false},
               %{name: "label", type: :utf8, nullable: false}
             ]},
          nullable: false
        }
      ]
    }
  end

  defp id_schema do
    %F3.Schema{fields: [%{name: "id", type: {:int, 64, true}, nullable: false}]}
  end

  defp fresh_dir do
    dir = Path.join(System.tmp_dir!(), "f3-writer-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end
end
