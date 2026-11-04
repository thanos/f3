defmodule F3.Reader do
  @moduledoc """
  Projection, row-group selection, and batching.

  One decoder call decodes a whole encoding unit. Elixir then slices that
  column to `batch_size` rows. The default batch size is 8192. The committed
  fixtures are smaller than one unit, so a row group becomes one batch unless
  `batch_size` is set lower. `F3.stream/2` does not pread until the first pull.
  `Enum.take/2` stops further reads. The caller still owns `F3.close/1`.

  Chunk checksums are verified only when the footer stored one. The eight
  fixtures store none. `CUSTOM_WASM` and shared dictionaries are refused and
  the bytes are not executed.
  """

  alias F3.Checksum
  alias F3.Column
  alias F3.Error
  alias F3.Logical

  @default_batch_size 8192
  @allowed [:columns, :row_groups, :batch_size]

  @doc """
  Default number of rows in one batch.
  """
  @spec default_batch_size() :: pos_integer()
  def default_batch_size, do: @default_batch_size

  @doc """
  Reads the selected row groups into columnar batches.
  """
  @spec read(F3.File.t(), keyword()) :: {:ok, [F3.Batch.t()]} | {:error, F3.Error.t()}
  def read(file, opts) when is_list(opts) do
    with {:ok, decoder} <- open_decoder(file, :read),
         {:ok, plan} <- plan(file, opts, :read) do
      collect(plan, decoder, [])
    end
  end

  def read(_file, _opts) do
    {:error, Error.invalid_argument(:read, "options must be a keyword list")}
  end

  @doc """
  Lazy batches. The first pull reads the footer. Later pulls read encoding
  units. A pull that cannot decode throws `{:f3, %F3.Error{}}`.
  """
  @spec stream(F3.File.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, F3.Error.t()}
  def stream(file, opts) when is_list(opts) do
    with {:ok, decoder} <- open_decoder(file, :stream),
         :ok <- validate(opts, :stream) do
      stream =
        Stream.resource(
          fn -> {:new, file, opts, decoder} end,
          &pull/1,
          fn _acc -> :ok end
        )

      {:ok, stream}
    end
  end

  def stream(_file, _opts) do
    {:error, Error.invalid_argument(:stream, "options must be a keyword list")}
  end

  @doc """
  Refuses a shared dictionary or a Wasm encoding unit.
  """
  @spec reject_chunk(F3.RowGroup.chunk()) :: :ok | {:error, F3.Error.t()}
  def reject_chunk(%{dictionary: {:shared, index}}) do
    {:error, Error.unsupported_encoding(:read, "shared dictionary #{index} is not loaded")}
  end

  def reject_chunk(%{encunits: units}) do
    Enum.reduce_while(units, :ok, fn unit, :ok ->
      case reject_unit(unit) do
        :ok -> {:cont, :ok}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp pull({:new, file, opts, decoder}) do
    case plan(file, opts, :stream) do
      {:ok, plan} -> pull({:go, plan, decoder})
      {:error, %Error{} = error} -> throw({:f3, error})
    end
  end

  defp pull({:go, %{pending: [batch | rest]} = plan, decoder}) do
    {[batch], {:go, %{plan | pending: rest}, decoder}}
  end

  defp pull({:go, %{pending: [], groups: []} = plan, decoder}) do
    {:halt, {:go, plan, decoder}}
  end

  defp pull({:go, %{pending: [], groups: [group | groups]} = plan, decoder}) do
    case decode_group(plan, group, decoder) do
      {:ok, batches} -> pull({:go, %{plan | groups: groups, pending: batches}, decoder})
      {:error, %Error{} = error} -> throw({:f3, error})
    end
  end

  defp collect(%{groups: []} = _plan, _decoder, batches), do: {:ok, batches}

  defp collect(%{groups: [group | groups]} = plan, decoder, batches) do
    case decode_group(plan, group, decoder) do
      {:ok, more} -> collect(%{plan | groups: groups}, decoder, batches ++ more)
      {:error, %Error{}} = error -> error
    end
  end

  defp decode_group(plan, group, decoder) do
    names = Enum.map(plan.fields, & &1.name)

    with {:ok, needed} <- Logical.needed(plan.schema_fields, names),
         :ok <- columns_present?(group, needed, plan.operation),
         {:ok, count} <- chunk_count(group, needed, plan.operation),
         {:ok, logical} <-
           decode_chunks(plan, group, names, needed, count, decoder),
         :ok <- rows_match?(logical, plan.fields, group.num_rows, plan.operation) do
      {:ok, batches(logical, plan.fields, group.num_rows, plan.batch_size)}
    end
  end

  defp decode_chunks(_plan, _group, _names, _needed, 0, _decoder), do: {:ok, %{}}

  defp decode_chunks(plan, group, names, needed, count, decoder) do
    Enum.reduce_while(0..(count - 1)//1, {:ok, nil}, fn chunk_index, {:ok, acc} ->
      case one_chunk(plan, group, names, needed, chunk_index, decoder) do
        {:ok, logical} -> concat_named(acc, logical)
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp one_chunk(plan, group, names, needed, chunk_index, decoder) do
    with {:ok, physical} <- decode_needed(plan, group, needed, chunk_index, decoder) do
      Logical.assemble(plan.schema_fields, names, physical)
    end
  end

  defp decode_needed(plan, group, needed, chunk_index, decoder) do
    Enum.reduce_while(needed, {:ok, %{}}, fn {index, type}, {:ok, acc} ->
      column = Enum.at(group.columns, index)
      chunk = Enum.at(column.chunks, chunk_index)

      case decode_chunk(plan.file, chunk, type, decoder, plan.operation) do
        {:ok, decoded} -> {:cont, {:ok, Map.put(acc, index, decoded)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp decode_chunk(file, chunk, type, decoder, operation) do
    with :ok <- reject_chunk(chunk),
         {:ok, bytes} <- pread_chunk(file, chunk, operation),
         :ok <- Checksum.verify(bytes, chunk.checksum),
         {:ok, units} <- split_units(chunk.encunits, bytes, operation),
         {:ok, column} <- decode_units(chunk.dictionary, units, type, decoder, operation) do
      expect_rows(column, chunk.num_rows, operation)
    end
  end

  defp decode_units(_dictionary, [], type, _decoder, _operation) do
    {:ok, Column.empty(type)}
  end

  defp decode_units({:local, _indexes}, units, type, decoder, operation) do
    decode_local(units, type, decoder, nil, operation)
  end

  defp decode_units(_dictionary, units, type, decoder, operation) do
    decode_plain(units, type, decoder, nil, operation)
  end

  defp decode_plain([], _type, _decoder, acc, _operation), do: {:ok, acc}

  defp decode_plain([{unit, bytes} | rest], type, decoder, acc, operation) do
    with :ok <- reject_unit(unit),
         {:ok, column} <- decoder.decode(bytes, unit.compression, type),
         {:ok, acc} <- Column.concat(acc, column) do
      decode_plain(rest, type, decoder, acc, operation)
    end
  end

  defp decode_local([], _type, _decoder, acc, _operation), do: {:ok, acc}

  defp decode_local(
         [{dict_unit, dict_bytes}, {index_unit, index_bytes} | rest],
         type,
         decoder,
         acc,
         operation
       ) do
    with :ok <- reject_unit(dict_unit),
         :ok <- reject_unit(index_unit),
         {:ok, dict} <- decoder.decode(dict_bytes, dict_unit.compression, type),
         {:ok, index} <- decoder.decode(index_bytes, index_unit.compression, :integer),
         {:ok, gathered} <- Column.gather(dict, index),
         {:ok, acc} <- Column.concat(acc, gathered) do
      decode_local(rest, type, decoder, acc, operation)
    end
  end

  defp decode_local(_units, _type, _decoder, _acc, operation) do
    {:error, Error.corrupt(operation, "local dictionary encunits must come in pairs")}
  end

  defp reject_unit(%{encoding: :cascade, compression: compression})
       when compression in [:uncompressed, :zstd, :lz4], do: :ok

  defp reject_unit(%{encoding: :custom_wasm}) do
    {:error, Error.unsupported_encoding(:read, "CUSTOM_WASM is not executed")}
  end

  defp reject_unit(%{encoding: encoding, compression: compression}) do
    {:error,
     Error.unsupported_encoding(
       :read,
       "encoding #{inspect(encoding)} compression #{inspect(compression)}"
     )}
  end

  defp pread_chunk(file, chunk, operation) do
    case file.source_module.pread(file.source_state, chunk.offset, chunk.size) do
      {:ok, bytes} when byte_size(bytes) == chunk.size ->
        {:ok, bytes}

      {:ok, _short} ->
        {:error, Error.truncated(operation, "chunk is shorter than the footer says")}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp split_units(units, bytes, operation), do: split_units(units, bytes, [], operation)

  defp split_units([], <<>>, acc, _operation), do: {:ok, Enum.reverse(acc)}

  defp split_units([], _rest, _acc, operation) do
    {:error, Error.corrupt(operation, "chunk is longer than its encoding units")}
  end

  defp split_units([%{size: size} = unit | rest], bytes, acc, operation) do
    if byte_size(bytes) < size do
      {:error, Error.corrupt(operation, "encoding unit extends past its chunk")}
    else
      <<part::binary-size(^size), rest_bytes::binary>> = bytes
      split_units(rest, rest_bytes, [{unit, part} | acc], operation)
    end
  end

  defp expect_rows(%Column{num_rows: rows} = column, rows, _operation), do: {:ok, column}

  defp expect_rows(%Column{num_rows: actual}, expected, operation) do
    {:error, Error.corrupt(operation, "decoded #{actual} rows but the footer says #{expected}")}
  end

  defp concat_named(nil, logical), do: {:cont, {:ok, logical}}

  defp concat_named(left, right) do
    case merge_named(left, right) do
      {:ok, merged} -> {:cont, {:ok, merged}}
      {:error, %Error{}} = error -> {:halt, error}
    end
  end

  defp merge_named(left, right) do
    Enum.reduce_while(Map.keys(right), {:ok, left}, fn name, {:ok, acc} ->
      case Column.concat(Map.fetch!(acc, name), Map.fetch!(right, name)) do
        {:ok, column} -> {:cont, {:ok, Map.put(acc, name, column)}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp rows_match?(logical, fields, expected, operation) do
    if Enum.all?(fields, fn field -> logical[field.name].num_rows == expected end) do
      :ok
    else
      {:error, Error.corrupt(operation, "logical row count does not match the row group")}
    end
  end

  defp batches(_logical, _fields, 0, _batch_size), do: []

  defp batches(logical, fields, rows, batch_size) do
    emit(logical, fields, 0, rows, batch_size)
  end

  defp emit(_logical, _fields, pos, rows, _batch_size) when pos >= rows, do: []

  defp emit(logical, fields, pos, rows, batch_size) do
    length = min(batch_size, rows - pos)

    columns =
      Map.new(fields, fn field ->
        {field.name, Column.slice(Map.fetch!(logical, field.name), pos, length)}
      end)

    batch = %F3.Batch{columns: columns, num_rows: length, schema: %F3.Schema{fields: fields}}
    [batch | emit(logical, fields, pos + length, rows, batch_size)]
  end

  defp columns_present?(group, needed, operation) do
    if Enum.all?(needed, fn {index, _type} -> index < length(group.columns) end) do
      :ok
    else
      {:error,
       Error.corrupt(operation, "schema asks for a physical column the footer does not have")}
    end
  end

  defp chunk_count(_group, [], _operation), do: {:ok, 0}

  defp chunk_count(group, needed, operation) do
    counts =
      Enum.map(needed, fn {index, _type} ->
        length(Enum.at(group.columns, index).chunks)
      end)

    case Enum.uniq(counts) do
      [count] -> {:ok, count}
      _other -> {:error, Error.corrupt(operation, "columns do not share a chunk count")}
    end
  end

  defp plan(file, opts, operation) do
    with :ok <- validate(opts, operation),
         {:ok, metadata} <- F3.Footer.load(file, F3.Postscript.max_metadata_bytes()),
         {:ok, fields} <- project(metadata.schema, Keyword.get(opts, :columns), operation),
         :ok <- tree(metadata.logical_tree, metadata.schema.fields, operation),
         {:ok, groups} <-
           choose_groups(metadata.row_groups, Keyword.get(opts, :row_groups), operation) do
      {:ok,
       %{
         file: file,
         fields: fields,
         schema_fields: metadata.schema.fields,
         groups: groups,
         pending: [],
         batch_size: batch_size(opts),
         operation: operation
       }}
    end
  end

  defp tree(logical, fields, operation) do
    if Logical.matches?(logical, fields) do
      :ok
    else
      {:error, Error.corrupt(operation, "logical tree does not match the schema")}
    end
  end

  defp project(schema, nil, _operation), do: {:ok, schema.fields}

  defp project(schema, names, operation) do
    Enum.reduce_while(names, {:ok, []}, fn name, {:ok, acc} ->
      case Enum.find(schema.fields, &(&1.name == name)) do
        nil -> {:halt, {:error, Error.invalid_projection(operation, name)}}
        field -> {:cont, {:ok, [field | acc]}}
      end
    end)
    |> case do
      {:ok, fields} -> {:ok, Enum.reverse(fields)}
      error -> error
    end
  end

  defp choose_groups(groups, nil, _operation), do: {:ok, groups}

  defp choose_groups(groups, indexes, operation) do
    Enum.reduce_while(indexes, {:ok, []}, fn index, {:ok, acc} ->
      case Enum.at(groups, index, :missing) do
        :missing ->
          {:halt,
           {:error, Error.invalid_argument(operation, "row group #{index} is past the footer")}}

        group ->
          {:cont, {:ok, [group | acc]}}
      end
    end)
    |> case do
      {:ok, chosen} -> {:ok, Enum.reverse(chosen)}
      error -> error
    end
  end

  defp open_decoder(%F3.File{closed: true}, operation), do: {:error, Error.closed(operation)}

  defp open_decoder(%F3.File{}, operation) do
    case Application.get_env(:f3, :decoder, F3.Decoder.Native) do
      F3.Decoder.Native -> F3.Native.require_decoder(operation)
      module when is_atom(module) -> {:ok, module}
    end
  end

  defp open_decoder(_file, operation) do
    {:error, Error.invalid_argument(operation, "expected an F3.File")}
  end

  defp validate(opts, operation) do
    with :ok <- unknown(opts, operation),
         :ok <- columns_opt(Keyword.get(opts, :columns), operation),
         :ok <- groups_opt(Keyword.get(opts, :row_groups), operation) do
      batch_opt(Keyword.get(opts, :batch_size, @default_batch_size), operation)
    end
  end

  defp unknown(opts, operation) do
    case opts |> Keyword.keys() |> Enum.reject(&(&1 in @allowed)) do
      [] -> :ok
      keys -> {:error, Error.invalid_argument(operation, "unknown options: #{inspect(keys)}")}
    end
  end

  defp columns_opt(nil, _operation), do: :ok

  defp columns_opt(names, operation) when is_list(names) do
    if Enum.all?(names, &is_binary/1) do
      :ok
    else
      {:error, Error.invalid_argument(operation, "columns must be a list of field names")}
    end
  end

  defp columns_opt(_names, operation) do
    {:error, Error.invalid_argument(operation, "columns must be a list of field names")}
  end

  defp groups_opt(nil, _operation), do: :ok

  defp groups_opt(indexes, operation) when is_list(indexes) do
    if Enum.all?(indexes, &non_neg_integer?/1) do
      :ok
    else
      {:error, Error.invalid_argument(operation, "row_groups must be a list of indexes")}
    end
  end

  defp groups_opt(_indexes, operation) do
    {:error, Error.invalid_argument(operation, "row_groups must be a list of indexes")}
  end

  defp batch_opt(size, _operation) when is_integer(size) and size > 0, do: :ok

  defp batch_opt(_size, operation) do
    {:error, Error.invalid_argument(operation, "batch_size must be a positive integer")}
  end

  defp batch_size(opts), do: Keyword.get(opts, :batch_size, @default_batch_size)

  defp non_neg_integer?(value), do: is_integer(value) and value >= 0
end
