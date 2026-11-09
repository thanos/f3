defmodule F3.Inspection do
  @moduledoc """
  Text and JSON rendering of `F3.Metadata`.

  The JSON form is `F3.Metadata.to_map/1`. It has string keys and no column
  payloads. Text never prints file bytes.
  """

  alias F3.Metadata
  alias F3.Schema

  @doc """
  Renders metadata as text or JSON.

  `format` is `:text` or `:json`. `detail` adds row groups and sections when
  `format` is `:text`. JSON ignores `detail` and is `F3.Metadata.to_map/1`.
  Any other format raises `FunctionClauseError`. The text does not include
  column bytes.

  ## Examples

      iex> {:ok, file} = F3.open("test/fixtures/small.f3")
      iex> {:ok, meta} = F3.metadata(file)
      iex> F3.Inspection.render(meta, :text, false) =~ "rows: 3"
      true
  """
  @spec render(Metadata.t(), :text | :json, boolean()) :: String.t()
  def render(metadata, :json, _detail), do: JSON.encode!(Metadata.to_map(metadata))
  def render(metadata, :text, true), do: detail(metadata)
  def render(metadata, :text, false), do: compact(metadata)

  defp compact(meta) do
    rows = Enum.reduce(meta.row_groups, 0, fn group, acc -> acc + group.num_rows end)
    fields = Enum.map_join(meta.schema.fields, ", ", &field_text/1)

    """
    version: #{meta.major_version}.#{meta.minor_version}
    rows: #{rows}
    row_groups: #{length(meta.row_groups)}
    schema: #{fields}
    footer_bytes: #{meta.footer_size}
    metadata_bytes: #{meta.metadata_size}
    footer_compression: #{Metadata.compression_name(meta.footer_compression)}
    checksum_type: #{Metadata.checksum_name(meta.checksum_type)}
    data_checksum: #{hex(meta.data_checksum)}
    schema_checksum: #{hex(meta.schema_checksum)}
    """
    |> String.trim_trailing()
  end

  defp detail(meta) do
    [
      compact(meta),
      "\n\nlogical_tree: #{tree_text(meta.logical_tree)}\n",
      "encoding_versions:\n",
      versions_text(meta.encoding_versions),
      "optional_sections:\n",
      sections_text(meta.optional_sections),
      "shared_dictionary:\n",
      shared_text(meta.shared_dictionary),
      "row_groups:\n",
      groups_text(meta.row_groups)
    ]
    |> IO.iodata_to_binary()
    |> String.trim_trailing()
  end

  defp field_text(field) do
    mark = if field.nullable, do: "?", else: ""
    "#{field.name} #{Schema.type_label(field.type)}#{mark}"
  end

  defp tree_text(tree) do
    children = Enum.map_join(tree.children, ", ", &tree_text/1)
    suffix = if children == "", do: "", else: "(#{children})"
    Metadata.logical_name(tree.id) <> suffix
  end

  defp versions_text([]), do: "  (none)\n"

  defp versions_text(versions) do
    Enum.map(versions, fn version ->
      ver = version.version
      "  #{Metadata.encoding_name(version.encoding)} #{ver.major}.#{ver.minor}.#{ver.patch}\n"
    end)
  end

  defp sections_text([]), do: "  (none)\n"

  defp sections_text(sections) do
    Enum.map(sections, fn section ->
      "  #{section.name} offset=#{section.offset} size=#{section.size} compression=#{Metadata.compression_name(section.compression)}\n"
    end)
  end

  defp shared_text(nil), do: "  (none)\n"

  defp shared_text(shared) do
    schema =
      case shared.schema do
        %{fields: [_ | _] = fields} -> Enum.map_join(fields, ", ", &field_text/1)
        _other -> "(none)"
      end

    [
      "  chunks: #{length(shared.chunks)}\n",
      "  schema_bytes: #{shared.schema_bytes}\n",
      "  schema: #{schema}\n",
      Enum.map(shared.chunks, &chunk_text(&1, "  ")),
      Enum.map(Enum.with_index(shared.positions), fn {ids, index} ->
        "  position #{index}: #{inspect(ids)}\n"
      end)
    ]
  end

  defp groups_text(groups) do
    Enum.map(groups, fn group ->
      [
        "  group #{group.index} rows=#{group.num_rows} offset=#{group.byte_offset} size=#{group.byte_size}\n",
        Enum.map(group.columns, fn column ->
          name = column.name || "column_#{column.index}"

          [
            "    column #{column.index} #{name}\n",
            Enum.map(column.chunks, &chunk_text(&1, "      "))
          ]
        end)
      ]
    end)
  end

  defp chunk_text(chunk, indent) do
    checksum = if chunk.checksum, do: hex(chunk.checksum), else: "none"

    [
      "#{indent}chunk offset=#{chunk.offset} size=#{chunk.size} rows=#{chunk.num_rows} dictionary=#{dictionary_text(chunk.dictionary)} checksum=#{checksum}\n",
      Enum.map(chunk.encunits, fn unit ->
        wasm = if unit.wasm_id, do: " wasm_id=#{unit.wasm_id}", else: ""

        "#{indent}  encunit size=#{unit.size} rows=#{unit.num_rows} encoding=#{Metadata.encoding_name(unit.encoding)} compression=#{Metadata.compression_name(unit.compression)}#{wasm}\n"
      end)
    ]
  end

  defp dictionary_text(:none), do: "none"
  defp dictionary_text({:local, indexes}), do: "local#{inspect(indexes)}"
  defp dictionary_text({:shared, index}), do: "shared(#{index})"

  defp hex(value), do: "0x" <> String.upcase(Integer.to_string(value, 16))
end
