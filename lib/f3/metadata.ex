defmodule F3.Metadata do
  @moduledoc """
  File metadata from the postscript, the FlatBuffers footer, and the
  out-of-band column metadata those tables point at.

  Checksums are copied from the postscript. They are not recomputed.
  Optional section offsets are recorded and not read. Nothing in this
  struct is a Wasm module or a column payload.

  `to_map/1` is the JSON shape compared with the upstream reader. It uses
  string keys and does not include column names, which exist only on
  `row_groups` after the schema is aligned.
  """

  alias F3.RowGroup
  alias F3.Schema

  @type logical_id :: :flat | :list | :struct | :list_of_struct_of_primitive | non_neg_integer()

  @type logical_tree :: %{id: logical_id(), children: [logical_tree()]}

  @type encoding_version :: %{
          encoding: RowGroup.encoding(),
          version: %{major: non_neg_integer(), minor: non_neg_integer(), patch: non_neg_integer()}
        }

  @type section :: %{
          name: String.t(),
          offset: non_neg_integer(),
          size: non_neg_integer(),
          compression: RowGroup.compression()
        }

  @type shared_dictionary :: %{
          chunks: [RowGroup.chunk()],
          positions: [[non_neg_integer()]],
          schema: Schema.t() | nil,
          schema_bytes: non_neg_integer()
        }

  @type t :: %__MODULE__{
          major_version: non_neg_integer(),
          minor_version: non_neg_integer(),
          metadata_size: non_neg_integer(),
          footer_size: non_neg_integer(),
          footer_compression: :uncompressed,
          checksum_type: F3.Postscript.checksum_type(),
          data_checksum: non_neg_integer(),
          schema_checksum: non_neg_integer(),
          schema: Schema.t(),
          logical_tree: logical_tree(),
          encoding_versions: [encoding_version()],
          optional_sections: [section()],
          shared_dictionary: shared_dictionary() | nil,
          row_groups: [RowGroup.t()]
        }

  defstruct [
    :major_version,
    :minor_version,
    :metadata_size,
    :footer_size,
    :footer_compression,
    :checksum_type,
    :data_checksum,
    :schema_checksum,
    :schema,
    :logical_tree,
    encoding_versions: [],
    optional_sections: [],
    shared_dictionary: nil,
    row_groups: []
  ]

  @doc """
  Map compared with the committed upstream golden files.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = meta) do
    %{
      "postscript" => %{
        "metadata_size" => meta.metadata_size,
        "footer_size" => meta.footer_size,
        "footer_compression" => compression_name(meta.footer_compression),
        "checksum_type" => checksum_name(meta.checksum_type),
        "data_checksum" => meta.data_checksum,
        "schema_checksum" => meta.schema_checksum,
        "major_version" => meta.major_version,
        "minor_version" => meta.minor_version
      },
      "schema" => Enum.map(meta.schema.fields, &Schema.field_map/1),
      "logical_tree" => tree_map(meta.logical_tree),
      "encoding_versions" => Enum.map(meta.encoding_versions, &version_map/1),
      "optional_sections" => Enum.map(meta.optional_sections, &section_map/1),
      "shared_dictionary" => shared_map(meta.shared_dictionary),
      "row_groups" => Enum.map(meta.row_groups, &group_map/1)
    }
  end

  defp group_map(group) do
    %{
      "row_count" => group.num_rows,
      "offset" => group.byte_offset,
      "size" => group.byte_size,
      "columns" =>
        Enum.map(group.columns, fn column ->
          %{"chunks" => Enum.map(column.chunks, &chunk_map/1)}
        end)
    }
  end

  @doc false
  @spec chunk_map(RowGroup.chunk()) :: map()
  def chunk_map(chunk) do
    %{
      "offset" => chunk.offset,
      "size" => chunk.size,
      "num_rows" => chunk.num_rows,
      "checksum" => chunk.checksum,
      "dictionary" => dictionary_map(chunk.dictionary),
      "encunits" => Enum.map(chunk.encunits, &encunit_map/1)
    }
  end

  defp encunit_map(unit) do
    %{
      "size" => unit.size,
      "num_rows" => unit.num_rows,
      "encoding" => encoding_name(unit.encoding),
      "compression" => compression_name(unit.compression),
      "wasm_id" => unit.wasm_id
    }
  end

  defp dictionary_map(:none), do: %{"kind" => "none"}

  defp dictionary_map({:local, indexes}) do
    %{"kind" => "local", "encunit_indexes" => indexes}
  end

  defp dictionary_map({:shared, index}) do
    %{"kind" => "shared", "index" => index}
  end

  defp version_map(version) do
    %{
      "encoding" => encoding_name(version.encoding),
      "version" => "#{version.version.major}.#{version.version.minor}.#{version.version.patch}"
    }
  end

  defp section_map(section) do
    %{
      "name" => section.name,
      "offset" => section.offset,
      "size" => section.size,
      "compression" => compression_name(section.compression)
    }
  end

  defp shared_map(nil), do: nil

  defp shared_map(shared) do
    %{
      "chunks" => Enum.map(shared.chunks, &chunk_map/1),
      "positions" => shared.positions,
      "schema" => shared.schema && Enum.map(shared.schema.fields, &Schema.field_map/1),
      "schema_bytes" => shared.schema_bytes
    }
  end

  defp tree_map(nil), do: nil

  defp tree_map(tree) do
    %{
      "id" => logical_name(tree.id),
      "children" => Enum.map(tree.children, &tree_map/1)
    }
  end

  @doc false
  def compression_name(:uncompressed), do: "uncompressed"
  def compression_name(:zstd), do: "zstd"
  def compression_name(:lz4), do: "lz4"
  def compression_name(byte) when is_integer(byte), do: Integer.to_string(byte)

  @doc false
  def encoding_name(:cascade), do: "cascade"
  def encoding_name(:custom_wasm), do: "custom_wasm"
  def encoding_name(byte) when is_integer(byte), do: Integer.to_string(byte)

  @doc false
  def checksum_name(:xxhash), do: "xxhash"
  def checksum_name({:unknown, byte}), do: "unknown:#{byte}"

  @doc false
  def logical_name(:flat), do: "flat"
  def logical_name(:list), do: "list"
  def logical_name(:struct), do: "struct"
  def logical_name(:list_of_struct_of_primitive), do: "list_of_struct_of_primitive"
  def logical_name(byte) when is_integer(byte), do: Integer.to_string(byte)
end
