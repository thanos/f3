defmodule F3.RenderTest do
  use ExUnit.Case, async: true

  test "type labels and field maps cover the types the fixtures omit" do
    nested = %{
      name: "wrap",
      nullable: true,
      type:
        {:struct,
         [
           %{name: "n", type: :null, nullable: false},
           %{name: "b", type: :bool, nullable: false},
           %{name: "raw", type: :binary, nullable: false},
           %{name: "u", type: {:int, 32, false}, nullable: false},
           %{name: "h", type: {:float, :half}, nullable: false},
           %{name: "s", type: {:float, :single}, nullable: false},
           %{
             name: "xs",
             type: {:list, %{name: "item", type: :utf8, nullable: true}},
             nullable: false
           },
           %{name: "other", type: {:unsupported, 9}, nullable: false}
         ]}
    }

    assert F3.Schema.type_label(nested.type) ==
             "struct<n: null, b: bool, raw: binary, u: uint32, h: float16, s: float32, xs: list<utf8>, other: unsupported(9)>"

    assert F3.Schema.field_map(nested)["type"]["struct"]
           |> Enum.map(& &1["type"]) == [
             "null",
             "bool",
             "binary",
             "uint32",
             "float16",
             "float32",
             %{"list" => %{"name" => "item", "nullable" => true, "type" => "utf8"}},
             %{"unsupported" => 9}
           ]
  end

  test "detail text names dictionary kinds, checksums, wasm ids, and empty sections" do
    chunk = %{
      offset: 8,
      size: 16,
      num_rows: 2,
      dictionary: {:shared, 3},
      checksum: 255,
      encunits: [
        %{size: 16, num_rows: 2, encoding: 7, compression: 9, wasm_id: 4}
      ]
    }

    metadata = %F3.Metadata{
      major_version: 0,
      minor_version: 1,
      metadata_size: 10,
      footer_size: 4,
      footer_compression: :uncompressed,
      checksum_type: {:unknown, 4},
      data_checksum: 1,
      schema_checksum: 2,
      schema: %F3.Schema{
        fields: [%{name: "symbol", type: :utf8, nullable: true}]
      },
      logical_tree: %{
        id: :list_of_struct_of_primitive,
        children: [%{id: 6, children: []}]
      },
      encoding_versions: [],
      optional_sections: [],
      shared_dictionary: %{
        chunks: [chunk],
        positions: [[1, 2]],
        schema: %F3.Schema{fields: [%{name: "symbol", type: :utf8, nullable: false}]},
        schema_bytes: 3
      },
      row_groups: [
        %F3.RowGroup{
          index: 0,
          num_rows: 2,
          byte_offset: 0,
          byte_size: 16,
          columns: [%{index: 0, name: nil, chunks: [%{chunk | dictionary: {:local, [0]}}]}]
        }
      ]
    }

    text = F3.Inspection.render(metadata, :text, true)
    assert text =~ "symbol utf8?"
    assert text =~ "checksum_type: unknown:4"
    assert text =~ "logical_tree: list_of_struct_of_primitive(6)"
    assert text =~ "encoding_versions:\n  (none)"
    assert text =~ "optional_sections:\n  (none)"
    assert text =~ "schema: symbol utf8"
    assert text =~ "dictionary=shared(3)"
    assert text =~ "checksum=0xFF"
    assert text =~ "encoding=7"
    assert text =~ "compression=9"
    assert text =~ "wasm_id=4"
    assert text =~ "dictionary=local[0]"
    assert text =~ "column 0 column_0"
    assert text =~ "position 0: [1, 2]"

    map = F3.Metadata.to_map(metadata)
    assert map["postscript"]["checksum_type"] == "unknown:4"
    assert map["schema"] == [%{"name" => "symbol", "nullable" => true, "type" => "utf8"}]

    assert map["shared_dictionary"]["schema"] == [
             %{"name" => "symbol", "nullable" => false, "type" => "utf8"}
           ]

    assert hd(map["shared_dictionary"]["chunks"])["dictionary"]["kind"] == "shared"

    empty_shared = %{metadata | shared_dictionary: nil}
    assert F3.Inspection.render(empty_shared, :text, true) =~ "shared_dictionary:\n  (none)"
    assert F3.Metadata.to_map(empty_shared)["shared_dictionary"] == nil
    assert F3.Metadata.to_map(%{empty_shared | logical_tree: nil})["logical_tree"] == nil
  end

  test "dictionary and nested fixtures print the kinds the compact view hides" do
    {:ok, dictionary} = F3.open("test/fixtures/dictionary.f3")
    assert {:ok, text} = F3.inspect(dictionary, detail: true)
    assert text =~ "dictionary=local[]"

    {:ok, nested} = F3.open("test/fixtures/nested.f3")
    assert {:ok, detail} = F3.inspect(nested, detail: true)
    assert detail =~ "column 0 column_0"
    assert detail =~ "list<int32>"
  end
end
