defmodule F3.Footer do
  @moduledoc """
  Decodes an F3 footer into `F3.Metadata`.

  The footer FlatBuffers buffer is the last `footer_size` bytes of the
  metadata span. Column metadata is a separate FlatBuffers root in the
  bytes before that footer. Both reads stay inside the span already
  accepted by `F3.Postscript`. Wasm section payloads are not read.
  """

  alias F3.Error
  alias F3.FlatBuffer, as: FB
  alias F3.Metadata
  alias F3.Postscript
  alias F3.RowGroup
  alias F3.Schema

  @operation :metadata

  @doc """
  Reads the metadata span and returns the decoded file metadata.
  """
  @spec load(F3.File.t(), non_neg_integer()) :: {:ok, Metadata.t()} | {:error, Error.t()}
  def load(%F3.File{} = file, max) when is_integer(max) and max >= 0 do
    with {:ok, postscript} <- Postscript.decode(file, max),
         {:ok, span} <- read_span(file, postscript) do
      decode(span, postscript)
    end
  end

  @doc """
  Decodes a metadata span that was already bounds-checked.
  """
  @spec decode(binary(), Postscript.t()) :: {:ok, Metadata.t()} | {:error, Error.t()}
  def decode(span, %Postscript{} = postscript) when is_binary(span) do
    footer = binary_part(span, byte_size(span) - postscript.footer_size, postscript.footer_size)

    result =
      with {:ok, root} <- open_root(footer),
           {:ok, schema} <- schema(root),
           {:ok, tree} <- logical_tree(root),
           {:ok, groups} <- row_groups(root, span, postscript, schema),
           {:ok, versions} <- encoding_versions(root),
           {:ok, sections} <- optional_sections(root, postscript),
           {:ok, shared} <- shared_dictionary(root) do
        {:ok,
         %Metadata{
           major_version: postscript.major_version,
           minor_version: postscript.minor_version,
           metadata_size: postscript.metadata_size,
           footer_size: postscript.footer_size,
           footer_compression: postscript.footer_compression,
           checksum_type: postscript.checksum_type,
           data_checksum: postscript.data_checksum,
           schema_checksum: postscript.schema_checksum,
           schema: schema,
           logical_tree: tree,
           encoding_versions: versions,
           optional_sections: sections,
           shared_dictionary: shared,
           row_groups: groups
         }}
      end

    normalize(result)
  end

  defp read_span(file, postscript) do
    module = file.source_module
    state = file.source_state

    case module.pread(state, postscript.metadata_offset, postscript.metadata_size) do
      {:ok, binary} when byte_size(binary) == postscript.metadata_size ->
        {:ok, binary}

      {:ok, _short} ->
        {:error,
         Error.truncated(@operation, "metadata read was shorter than the postscript size")}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp schema(root) do
    case FB.bytes(root, 0) do
      {:ok, nil} ->
        corrupt("schema is missing")

      {:ok, ipc} ->
        with {:ok, message} <- open_root(ipc),
             {:ok, header} <- schema_header(message),
             {:ok, fields} <- FB.tables(header, 1),
             {:ok, decoded} <- map_ok(fields, &arrow_field/1) do
          {:ok, %Schema{fields: decoded}}
        end

      {:error, reason} ->
        flat_error(reason)
    end
  end

  defp schema_header(message) do
    case FB.union(message, 1) do
      {:ok, {1, header}} -> {:ok, header}
      {:ok, :none} -> corrupt("Arrow message has no schema header")
      {:ok, {type, _header}} -> corrupt("Arrow message header #{type} is not a schema")
      {:error, reason} -> flat_error(reason)
    end
  end

  defp arrow_field(field) do
    with {:ok, name} <- required_string(field, 0, "field name"),
         {:ok, nullable} <- FB.scalar(field, 1, :bool, false),
         {:ok, type} <- arrow_type(field) do
      {:ok, %{name: name, type: type, nullable: nullable}}
    end
  end

  defp arrow_type(field) do
    with {:ok, children} <- FB.tables(field, 5),
         {:ok, decoded_children} <- map_ok(children, &arrow_field/1),
         {:ok, union} <- FB.union(field, 2) do
      build_type(union, decoded_children)
    end
  end

  defp build_type(:none, _children), do: {:ok, {:unsupported, 0}}
  defp build_type({1, _null}, _children), do: {:ok, :null}
  defp build_type({4, _binary}, _children), do: {:ok, :binary}
  defp build_type({5, _utf8}, _children), do: {:ok, :utf8}
  defp build_type({6, _bool}, _children), do: {:ok, :bool}

  defp build_type({2, int}, _children) do
    with {:ok, width} <- FB.scalar(int, 0, :i32, 0),
         {:ok, signed} <- FB.scalar(int, 1, :bool, false) do
      if width > 0 do
        {:ok, {:int, width, signed}}
      else
        corrupt("integer width is zero")
      end
    end
  end

  defp build_type({3, float}, _children) do
    case FB.scalar(float, 0, :i16, 0) do
      {:ok, 0} -> {:ok, {:float, :half}}
      {:ok, 1} -> {:ok, {:float, :single}}
      {:ok, 2} -> {:ok, {:float, :double}}
      {:ok, other} -> {:ok, {:unsupported, other}}
      {:error, reason} -> flat_error(reason)
    end
  end

  defp build_type({12, _list}, children) do
    case children do
      [child] -> {:ok, {:list, child}}
      _other -> corrupt("list field does not have one child")
    end
  end

  defp build_type({13, _struct}, children), do: {:ok, {:struct, children}}

  defp build_type({type, _table}, _children) when is_integer(type),
    do: {:ok, {:unsupported, type}}

  defp logical_tree(root) do
    case FB.table(root, 1) do
      {:ok, nil} -> corrupt("logical tree is missing")
      {:ok, tree} -> logical_node(tree)
      {:error, reason} -> flat_error(reason)
    end
  end

  defp logical_node(tree) do
    with {:ok, id} <- FB.scalar(tree, 0, :u8, 0),
         {:ok, children} <- FB.tables(tree, 1),
         {:ok, decoded} <- map_ok(children, &logical_node/1) do
      {:ok, %{id: logical_id(id), children: decoded}}
    end
  end

  defp logical_id(0), do: :flat
  defp logical_id(1), do: :list
  defp logical_id(2), do: :struct
  defp logical_id(3), do: :list_of_struct_of_primitive
  defp logical_id(other), do: other

  defp row_groups(root, span, postscript, schema) do
    case FB.table(root, 2) do
      {:ok, nil} ->
        corrupt("row groups are missing")

      {:ok, groups} ->
        with {:ok, counts} <- FB.uints(groups, 0, 4),
             {:ok, offsets} <- FB.uints(groups, 1, 8),
             {:ok, sizes} <- FB.uints(groups, 2, 4),
             {:ok, metas} <- FB.tables(groups, 3),
             :ok <- same_length([counts, offsets, sizes, metas]) do
          groups =
            [counts, offsets, sizes, metas]
            |> Enum.zip()
            |> Enum.with_index()
            |> map_ok(fn {{count, offset, size, meta}, index} ->
              one_group(index, count, offset, size, meta, span, postscript, schema)
            end)

          groups
        end

      {:error, reason} ->
        flat_error(reason)
    end
  end

  defp one_group(index, count, offset, size, meta, span, postscript, schema) do
    with {:ok, sections} <- FB.tables(meta, 0),
         {:ok, columns} <-
           map_ok(Enum.with_index(sections), fn {section, column_index} ->
             column(section, column_index, span, postscript)
           end) do
      {:ok,
       %RowGroup{
         index: index,
         num_rows: count,
         byte_offset: offset,
         byte_size: size,
         columns: name_columns(columns, schema)
       }}
    end
  end

  defp column(section, index, span, postscript) do
    with {:ok, offset} <- FB.scalar(section, 0, :u64, 0),
         {:ok, size} <- FB.scalar(section, 1, :u32, 0),
         {:ok, bytes} <- column_bytes(span, postscript, offset, size),
         {:ok, root} <- open_root(bytes),
         {:ok, chunks} <- FB.tables(root, 0),
         {:ok, decoded} <- map_ok(chunks, &chunk/1) do
      {:ok, %{index: index, name: nil, chunks: decoded}}
    end
  end

  defp column_bytes(span, postscript, offset, size) do
    metadata_end = postscript.footer_offset
    start = postscript.metadata_offset

    cond do
      size == 0 ->
        corrupt("column metadata size is empty")

      offset < start or offset > metadata_end ->
        corrupt("column metadata is outside the metadata span")

      size > metadata_end - offset ->
        corrupt("column metadata overlaps the footer")

      true ->
        local = offset - start
        {:ok, binary_part(span, local, size)}
    end
  end

  defp chunk(table) do
    with {:ok, offset} <- FB.scalar(table, 0, :u64, 0),
         {:ok, size} <- FB.scalar(table, 1, :u32, 0),
         {:ok, rows} <- FB.scalar(table, 2, :u64, 0),
         {:ok, dictionary} <- dictionary(table),
         {:ok, units} <- FB.tables(table, 5),
         {:ok, decoded} <- map_ok(units, &encunit/1),
         {:ok, checksum} <- FB.optional_scalar(table, 6, :u64) do
      {:ok,
       %{
         offset: offset,
         size: size,
         num_rows: rows,
         dictionary: dictionary,
         checksum: checksum,
         encunits: decoded
       }}
    end
  end

  defp dictionary(table) do
    case FB.union(table, 3) do
      {:ok, :none} ->
        {:ok, :none}

      {:ok, {1, _empty}} ->
        {:ok, :none}

      {:ok, {2, local}} ->
        case FB.uints(local, 0, 4) do
          {:ok, indexes} -> {:ok, {:local, indexes}}
          {:error, reason} -> flat_error(reason)
        end

      {:ok, {3, shared}} ->
        case FB.scalar(shared, 0, :u32, 0) do
          {:ok, index} -> {:ok, {:shared, index}}
          {:error, reason} -> flat_error(reason)
        end

      {:ok, {type, _other}} ->
        corrupt("unknown dictionary encoding #{type}")

      {:error, reason} ->
        flat_error(reason)
    end
  end

  defp encunit(table) do
    with {:ok, size} <- FB.scalar(table, 0, :u32, 0),
         {:ok, rows} <- FB.scalar(table, 2, :u32, 0),
         {:ok, compression} <- FB.scalar(table, 3, :u8, 0),
         {:ok, encoding, wasm_id} <- encoding(table) do
      {:ok,
       %{
         size: size,
         num_rows: rows,
         encoding: encoding,
         compression: compression_atom(compression),
         wasm_id: wasm_id
       }}
    end
  end

  defp encoding(table) do
    case FB.table(table, 1) do
      {:ok, nil} ->
        {:ok, :cascade, nil}

      {:ok, encoding} ->
        with {:ok, type} <- FB.scalar(encoding, 0, :u8, 0),
             {:ok, wasm_id} <- wasm_id(encoding) do
          {:ok, encoding_atom(type), wasm_id}
        end

      {:error, reason} ->
        flat_error(reason)
    end
  end

  defp wasm_id(encoding) do
    case FB.table(encoding, 1) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, wasm} ->
        case FB.optional_scalar(wasm, 0, :u32) do
          {:ok, nil} -> {:ok, nil}
          {:ok, id} -> {:ok, id}
          {:error, reason} -> flat_error(reason)
        end

      {:error, reason} ->
        flat_error(reason)
    end
  end

  defp encoding_versions(root) do
    with {:ok, versions} <- FB.tables(root, 4) do
      map_ok(versions, fn version ->
        with {:ok, type} <- FB.scalar(version, 0, :u8, 0),
             {:ok, semver} <- FB.table(version, 1),
             {:ok, decoded} <- semver(semver) do
          {:ok, %{encoding: encoding_atom(type), version: decoded}}
        end
      end)
    end
  end

  defp semver(nil), do: corrupt("encoding version is missing")

  defp semver(table) do
    with {:ok, major} <- FB.scalar(table, 0, :u64, 0),
         {:ok, minor} <- FB.scalar(table, 1, :u64, 0),
         {:ok, patch} <- FB.scalar(table, 2, :u64, 0) do
      {:ok, %{major: major, minor: minor, patch: patch}}
    end
  end

  defp optional_sections(root, postscript) do
    case FB.table(root, 3) do
      {:ok, nil} ->
        {:ok, []}

      {:ok, sections} ->
        with {:ok, names} <- string_vector(sections, 0),
             {:ok, offsets} <- FB.uints(sections, 1, 8),
             {:ok, sizes} <- FB.uints(sections, 2, 4),
             {:ok, compressions} <- byte_vector(sections, 3),
             :ok <- same_length([names, offsets, sizes, compressions]) do
          [names, offsets, sizes, compressions]
          |> Enum.zip()
          |> map_ok(fn {name, offset, size, compression} ->
            section(name, offset, size, compression, postscript)
          end)
        end

      {:error, reason} ->
        flat_error(reason)
    end
  end

  defp section(name, offset, size, compression, postscript) do
    limit = postscript.file_size - F3.Format.postscript_size()

    cond do
      offset > limit ->
        corrupt("optional section starts past the postscript")

      size > limit - offset ->
        corrupt("optional section overlaps the postscript")

      true ->
        {:ok,
         %{
           name: name,
           offset: offset,
           size: size,
           compression: compression_atom(compression)
         }}
    end
  end

  defp shared_dictionary(root) do
    case FB.table(root, 5) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, table} ->
        with {:ok, chunks} <- FB.tables(table, 0),
             {:ok, decoded_chunks} <- map_ok(chunks, &chunk/1),
             {:ok, positions} <- FB.tables(table, 1),
             {:ok, decoded_positions} <- map_ok(positions, &chunk_ids/1),
             {:ok, schema_bytes} <- FB.bytes(table, 2),
             {:ok, schema} <- shared_schema(schema_bytes) do
          {:ok,
           %{
             chunks: decoded_chunks,
             positions: decoded_positions,
             schema: schema,
             schema_bytes: if(schema_bytes, do: byte_size(schema_bytes), else: 0)
           }}
        end

      {:error, reason} ->
        flat_error(reason)
    end
  end

  defp chunk_ids(table) do
    case FB.uints(table, 0, 4) do
      {:ok, ids} -> {:ok, ids}
      {:error, reason} -> flat_error(reason)
    end
  end

  defp shared_schema(nil), do: {:ok, nil}
  defp shared_schema(<<>>), do: {:ok, nil}

  defp shared_schema(bytes) do
    with {:ok, message} <- open_root(bytes),
         {:ok, header} <- schema_header(message),
         {:ok, fields} <- FB.tables(header, 1),
         {:ok, decoded} <- map_ok(fields, &arrow_field/1) do
      {:ok, %Schema{fields: decoded}}
    end
  end

  defp string_vector(table, index) do
    case FB.string_vector(table, index) do
      {:ok, names} -> {:ok, names}
      {:error, reason} -> flat_error(reason)
    end
  end

  defp name_columns(columns, schema) do
    names = column_names(schema.fields, length(columns))

    Enum.zip(columns, names)
    |> Enum.map(fn {column, name} -> %{column | name: name} end)
  end

  defp column_names(fields, count) do
    top = Enum.map(fields, & &1.name)
    leaves = leaf_names(fields, nil)

    cond do
      length(top) == count -> top
      length(leaves) == count -> leaves
      true -> List.duplicate(nil, count)
    end
  end

  defp leaf_names(fields, parent) do
    Enum.flat_map(fields, fn field ->
      label = if parent, do: parent <> "." <> field.name, else: field.name

      case field.type do
        {:struct, children} -> leaf_names(children, label)
        {:list, child} -> leaf_names([child], label)
        _other -> [label]
      end
    end)
  end

  defp encoding_atom(0), do: :cascade
  defp encoding_atom(255), do: :custom_wasm
  defp encoding_atom(other), do: other

  defp compression_atom(0), do: :uncompressed
  defp compression_atom(1), do: :zstd
  defp compression_atom(2), do: :lz4
  defp compression_atom(other), do: other

  defp same_length(lists) do
    lengths = Enum.map(lists, &length/1)

    if Enum.uniq(lengths) |> length() == 1 do
      :ok
    else
      corrupt("repeated footer fields have different lengths")
    end
  end

  defp required_string(table, index, what) do
    case FB.string(table, index) do
      {:ok, nil} -> corrupt("#{what} is missing")
      {:ok, value} -> {:ok, value}
      {:error, reason} -> flat_error(reason)
    end
  end

  defp map_ok(items, fun) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
        :error -> {:halt, corrupt("metadata field is invalid")}
      end
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      {:error, %Error{}} = error -> error
      {:error, reason} -> flat_error(reason)
    end
  end

  defp open_root(bin) do
    case FB.root(bin) do
      {:ok, root} -> {:ok, root}
      {:error, reason} -> flat_error(reason)
    end
  end

  defp byte_vector(table, index) do
    case FB.bytes(table, index) do
      {:ok, nil} -> {:ok, []}
      {:ok, raw} -> {:ok, :binary.bin_to_list(raw)}
      {:error, reason} -> flat_error(reason)
    end
  end

  defp normalize({:error, :corrupt}), do: flat_error(:corrupt)
  defp normalize({:error, :depth}), do: flat_error(:depth)
  defp normalize(other), do: other

  defp flat_error(:depth), do: corrupt("metadata nesting is too deep")
  defp flat_error(:corrupt), do: corrupt("footer metadata is not valid FlatBuffers")
  defp flat_error(%Error{} = error), do: {:error, error}

  defp corrupt(message), do: {:error, Error.corrupt_metadata(@operation, message)}
end
