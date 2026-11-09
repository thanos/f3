defmodule F3.Writer do
  @moduledoc """
  Local F3 writer.

  `open/2` checks the schema and options, then starts the out-of-process
  helper when `F3_BUILD_NATIVE=1`. Batches are sent one at a time. `close/1`
  finishes the helper and renames a temp file onto the destination. A failed
  finish deletes the temp file and leaves an existing destination unchanged.
  The rename is local-filesystem behavior, not a remote write.

  Without the native helper, a valid `open/2` returns `:not_implemented` and
  creates no file. Wasm is not written.
  """

  @enforce_keys [:port, :schema, :path, :temp, :closed]
  defstruct [:port, :schema, :path, :temp, :closed]

  @typedoc """
  One local writer.

  `port` is the helper port, or `nil` before it starts. `schema` is the
  accepted logical schema. `path` is the destination. `temp` is the file
  renamed onto `path` at `close/1`. `closed` is true after a successful close.
  """
  @type t :: %__MODULE__{
          port: port() | nil,
          schema: F3.Schema.t(),
          path: Path.t(),
          temp: Path.t() | nil,
          closed: boolean()
        }

  @default_iounit 8 * 1024 * 1024
  @max_iounit 64 * 1024 * 1024
  @allowed [:schema, :compression, :row_group_rows, :iounit_bytes, :checksum]

  @primitives %{
    bool: :bool,
    utf8: :utf8,
    int64: {:int, 64, true},
    int32: {:int, 32, true},
    uint64: {:int, 64, false},
    uint32: {:int, 32, false},
    uint16: {:int, 16, false},
    uint8: {:int, 8, false},
    float64: {:float, :double},
    float32: {:float, :single}
  }

  @widths %{i64: 8, i32: 4, u64: 8, u32: 4, u16: 2, u8: 1, f64: 8, f32: 4, bool: 1}
  @tags %{bool: 1, utf8: 2, i64: 3, i32: 4, u64: 5, u32: 6, u16: 7, u8: 8, f64: 9, f32: 10}

  @doc """
  Opens a writer for `path`.

  `schema:` is a field keyword list or an `%F3.Schema{}`. A bare `:int64` is
  non-null. `{:float64, null: true}` is nullable. `compression:` is
  `:uncompressed` (the default), `:zstd`, or `:lz4`. `row_group_rows:` starts
  a new row group after at least that many rows. `iounit_bytes:` defaults to
  8 MiB and is rejected above 64 MiB.   `checksum: true` stores a per-IOUnit
  xxHash.

  A missing schema, an unknown option, and an IOUnit above 64 MiB return
  an error and create no file. Without the native helper, a valid schema
  returns `:not_implemented` and also creates no file. These checks do not
  raise.

  ## Examples

      iex> {:error, error} = F3.Writer.open("unused.f3", [])
      iex> error.message
      "schema is required"

      iex> {:error, error} = F3.Writer.open("unused.f3", schema: [id: :int64], source: :remote)
      iex> error.message
      "unknown option source"

      iex> opts = [schema: [price: {:float64, null: true}], iounit_bytes: 64 * 1024 * 1024 + 1]
      iex> {:error, error} = F3.Writer.open("unused.f3", opts)
      iex> error.category
      :resource_limit
  """
  @spec open(Path.t(), keyword()) :: {:ok, t()} | {:error, F3.Error.t()}
  def open(path, opts \\ [])

  def open(path, opts) when is_binary(path) and is_list(opts) do
    with {:ok, schema, options} <- prepare(opts) do
      launch(path, schema, options)
    end
  end

  def open(_path, _opts) do
    {:error, F3.Error.invalid_argument(:writer_open, "path must be a local file path")}
  end

  @doc """
  Writes one `%F3.Batch{}` or a list of row maps.

  Row maps may use atom or string keys. A missing key is null only when the
  field is nullable. An integer outside the field width is `:invalid_type`.
  A binary that is not UTF-8 is `:invalid_argument`. An empty batch is
  accepted and does not call the helper. A value that is not a writer is
  `:not_implemented`. This does not raise.

  ## Examples

      iex> {:error, error} = F3.Writer.write(:nope, [])
      iex> error.category
      :not_implemented
  """
  @spec write(t(), F3.Batch.t() | [map()]) :: :ok | {:error, F3.Error.t()}
  def write(%__MODULE__{closed: true}, _batch) do
    {:error, F3.Error.closed(:writer_write)}
  end

  def write(%__MODULE__{} = writer, %F3.Batch{num_rows: 0} = batch) do
    if batch.schema == writer.schema do
      :ok
    else
      {:error, F3.Error.invalid_argument(:writer_write, "batch schema does not match the writer")}
    end
  end

  def write(%__MODULE__{} = writer, %F3.Batch{} = batch) do
    with {:ok, frame} <- frame_batch(writer.schema, batch) do
      command(writer, frame)
    end
  end

  def write(%__MODULE__{}, []) do
    :ok
  end

  def write(%__MODULE__{} = writer, rows) when is_list(rows) do
    with {:ok, frame} <- frame_rows(writer.schema, rows) do
      command(writer, frame)
    end
  end

  def write(%__MODULE__{}, _batch) do
    {:error,
     F3.Error.invalid_argument(:writer_write, "batch must be an F3.Batch or a list of row maps")}
  end

  def write(_writer, _batch) do
    {:error, F3.Error.not_implemented(:writer_write)}
  end

  @doc """
  Finishes the file and renames it onto the destination.

  A second call returns the same closed handle. A value that is not a
  writer is `:not_implemented`.

  ## Examples

      iex> {:error, error} = F3.Writer.close(:nope)
      iex> error.reason
      :writer_close
  """
  @spec close(t()) :: {:ok, t()} | {:error, F3.Error.t()}
  def close(%__MODULE__{closed: true} = writer), do: {:ok, writer}

  def close(%__MODULE__{} = writer) do
    finish(writer, 0)
  end

  def close(_writer) do
    {:error, F3.Error.not_implemented(:writer_close)}
  end

  @doc false
  @spec fail_finish(t()) :: {:error, F3.Error.t()}
  def fail_finish(%__MODULE__{} = writer), do: finish(writer, 1)

  @doc false
  @spec encode(keyword() | F3.Schema.t(), [map()] | F3.Batch.t()) ::
          {:ok, binary()} | {:error, F3.Error.t()}
  def encode(schema, rows) when is_list(rows) do
    with {:ok, schema} <- accept_schema(schema),
         {:ok, frame} <- frame_rows(schema, rows) do
      {:ok, IO.iodata_to_binary([schema_frame(schema), frame])}
    end
  end

  def encode(schema, %F3.Batch{} = batch) do
    with {:ok, schema} <- accept_schema(schema),
         {:ok, frame} <- frame_batch(schema, batch) do
      {:ok, IO.iodata_to_binary([schema_frame(schema), frame])}
    end
  end

  @doc false
  @spec explain_helper(binary()) :: F3.Error.t()
  def explain_helper(data) when is_binary(data), do: helper_error(data)

  @doc false
  @spec executable() :: Path.t()
  def executable, do: Application.app_dir(:f3, "priv/native/f3_write")

  defp prepare(opts) do
    with :ok <- known_opts(opts),
         {:ok, schema} <- schema_opt(Keyword.get(opts, :schema)),
         {:ok, compression} <- compression_opt(Keyword.get(opts, :compression, :uncompressed)),
         {:ok, iounit} <- iounit_opt(Keyword.get(opts, :iounit_bytes, @default_iounit)),
         {:ok, row_group} <- row_group_opt(Keyword.get(opts, :row_group_rows)),
         {:ok, checksum} <- checksum_opt(Keyword.get(opts, :checksum, false)) do
      {:ok, schema,
       %{compression: compression, iounit: iounit, row_group: row_group, checksum: checksum}}
    end
  end

  defp known_opts(opts) do
    unknown = opts |> Keyword.keys() |> Enum.reject(&(&1 in @allowed))

    case unknown do
      [] -> :ok
      [key | _] -> {:error, F3.Error.invalid_argument(:writer_open, "unknown option #{key}")}
    end
  end

  defp accept_schema(schema), do: schema_opt(schema)

  defp schema_opt(%F3.Schema{fields: fields} = schema) when fields != [] do
    if Enum.all?(fields, &claimed_field?/1) do
      {:ok, schema}
    else
      {:error, F3.Error.invalid_type(:writer_open, "schema contains an unclaimed type")}
    end
  end

  defp schema_opt(fields) when is_list(fields) and fields != [] do
    Enum.reduce_while(fields, {:ok, []}, fn
      {name, spec}, {:ok, acc} when is_atom(name) ->
        case normalize_spec(spec) do
          {:ok, type, nullable} ->
            {:cont, {:ok, [%{name: Atom.to_string(name), type: type, nullable: nullable} | acc]}}

          {:error, %F3.Error{}} = error ->
            {:halt, error}
        end

      _other, _acc ->
        {:halt,
         {:error, F3.Error.invalid_argument(:writer_open, "schema field is not a name and type")}}
    end)
    |> case do
      {:ok, fields} -> {:ok, %F3.Schema{fields: Enum.reverse(fields)}}
      {:error, %F3.Error{}} = error -> error
    end
  end

  defp schema_opt(_schema) do
    {:error, F3.Error.invalid_argument(:writer_open, "schema is required")}
  end

  defp claimed_field?(%{name: name, type: type, nullable: nullable})
       when is_binary(name) and is_boolean(nullable) do
    match?({:ok, _}, type_kind(type))
  end

  defp claimed_field?(_field), do: false

  defp normalize_spec({:list, inner}) do
    with {:ok, type, nullable} <- normalize_spec(inner) do
      {:ok, {:list, %{name: "item", type: type, nullable: nullable}}, false}
    end
  end

  defp normalize_spec({:struct, fields}) when is_list(fields) do
    with {:ok, schema} <- schema_opt(fields) do
      {:ok, {:struct, schema.fields}, false}
    end
  end

  defp normalize_spec({inner, opts}) when is_list(opts) do
    if null_opts?(opts) do
      with {:ok, type, _null} <- normalize_spec(inner) do
        {:ok, type, Keyword.get(opts, :null, false)}
      end
    else
      {:error, F3.Error.invalid_type(:writer_open, "type is not a writer type")}
    end
  end

  defp normalize_spec(kind) when is_map_key(@primitives, kind) do
    {:ok, Map.fetch!(@primitives, kind), false}
  end

  defp normalize_spec(kind) when is_atom(kind) do
    {:error, F3.Error.invalid_type(:writer_open, "#{kind} is not a writer type")}
  end

  defp normalize_spec(_kind) do
    {:error, F3.Error.invalid_type(:writer_open, "type is not a writer type")}
  end

  defp null_opts?(opts) do
    Keyword.keyword?(opts) and
      Enum.all?(opts, fn {key, value} -> key == :null and is_boolean(value) end)
  end

  defp compression_opt(value) when value in [:uncompressed, :zstd, :lz4], do: {:ok, value}

  defp compression_opt(_value) do
    {:error,
     F3.Error.invalid_argument(:writer_open, "compression must be uncompressed, zstd, or lz4")}
  end

  defp iounit_opt(value) when is_integer(value) and value > 0 and value <= @max_iounit,
    do: {:ok, value}

  defp iounit_opt(value) when is_integer(value) and value > @max_iounit do
    {:error, F3.Error.resource_limit(:writer_open, "iounit_bytes is above 64 MiB", %{})}
  end

  defp iounit_opt(_value) do
    {:error, F3.Error.invalid_argument(:writer_open, "iounit_bytes must be a positive integer")}
  end

  defp row_group_opt(nil), do: {:ok, nil}

  defp row_group_opt(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp row_group_opt(_value) do
    {:error, F3.Error.invalid_argument(:writer_open, "row_group_rows must be a positive integer")}
  end

  defp checksum_opt(value) when is_boolean(value), do: {:ok, value}

  defp checksum_opt(_value) do
    {:error, F3.Error.invalid_argument(:writer_open, "checksum must be true or false")}
  end

  defp launch(path, schema, options) do
    native? = native_build?()

    cond do
      not File.dir?(Path.dirname(path)) ->
        {:error, F3.Error.io(:writer_open, :enoent, %{path: path})}

      not native? ->
        {:error, F3.Error.not_implemented(:writer_open)}

      not File.regular?(executable()) ->
        {:error, F3.Error.native_unavailable(:writer_open)}

      true ->
        start_port(path, schema, options)
    end
  end

  defp start_port(path, schema, options) do
    temp = Path.join(Path.dirname(path), temp_name(path))

    with :ok <- touch(temp),
         {:ok, port} <- open_port(temp, options) do
      case command(%{port: port}, schema_frame(schema)) do
        :ok ->
          {:ok, %__MODULE__{port: port, schema: schema, path: path, temp: temp, closed: false}}

        {:error, %F3.Error{}} = error ->
          stop_port(port)
          File.rm(temp)
          error
      end
    else
      {:error, %F3.Error{}} = error ->
        File.rm(temp)
        error
    end
  end

  defp temp_name(path) do
    "." <>
      Path.basename(path) <>
      "." <> Integer.to_string(System.unique_integer([:positive])) <> ".f3tmp"
  end

  defp touch(path) do
    case File.touch(path) do
      :ok -> :ok
      {:error, reason} -> {:error, F3.Error.io(:writer_open, reason, %{path: path})}
    end
  end

  defp open_port(temp, options) do
    port =
      Port.open({:spawn_executable, executable()}, [
        :binary,
        :exit_status,
        :hide,
        {:packet, 4},
        {:args, port_args(options, temp)}
      ])

    {:ok, port}
  end

  defp port_args(options, temp) do
    args = [
      "write",
      "--compression",
      Atom.to_string(options.compression),
      "--iounit-bytes",
      Integer.to_string(options.iounit)
    ]

    args = if options.checksum, do: args ++ ["--checksum"], else: args

    args =
      if options.row_group do
        args ++ ["--row-group-rows", Integer.to_string(options.row_group)]
      else
        args
      end

    args ++ [temp]
  end

  defp schema_frame(%F3.Schema{fields: fields}) do
    [<<1, length(fields)::unsigned-little-32>> | Enum.map(fields, &encode_field/1)]
  end

  defp encode_field(%{name: name, type: type, nullable: nullable}) do
    flag = if nullable, do: 1, else: 0
    [<<byte_size(name)::unsigned-little-16>>, name, <<flag>>, encode_type(type)]
  end

  defp encode_type({:list, field}), do: [<<11>>, encode_field(field)]

  defp encode_type({:struct, fields}) do
    [<<12, length(fields)::unsigned-little-16>> | Enum.map(fields, &encode_field/1)]
  end

  defp encode_type(type) do
    {:ok, kind} = type_kind(type)
    <<Map.fetch!(@tags, kind)>>
  end

  defp type_kind(:bool), do: {:ok, :bool}
  defp type_kind(:utf8), do: {:ok, :utf8}
  defp type_kind({:int, 64, true}), do: {:ok, :i64}
  defp type_kind({:int, 32, true}), do: {:ok, :i32}
  defp type_kind({:int, 64, false}), do: {:ok, :u64}
  defp type_kind({:int, 32, false}), do: {:ok, :u32}
  defp type_kind({:int, 16, false}), do: {:ok, :u16}
  defp type_kind({:int, 8, false}), do: {:ok, :u8}
  defp type_kind({:float, :double}), do: {:ok, :f64}
  defp type_kind({:float, :single}), do: {:ok, :f32}
  defp type_kind({:list, field}), do: if(claimed_field?(field), do: {:ok, :list}, else: :error)

  defp type_kind({:struct, fields}),
    do: if(Enum.all?(fields, &claimed_field?/1), do: {:ok, :struct}, else: :error)

  defp type_kind(_type), do: :error

  defp frame_rows(%F3.Schema{fields: fields}, rows) do
    with {:ok, columns} <- rows_to_columns(fields, rows) do
      {:ok, [<<2, length(rows)::unsigned-little-32>> | columns]}
    end
  end

  defp frame_batch(schema, %F3.Batch{schema: batch_schema, num_rows: rows, columns: columns}) do
    cond do
      batch_schema == nil ->
        {:error, F3.Error.invalid_argument(:writer_write, "batch has no schema")}

      batch_schema != schema ->
        {:error,
         F3.Error.invalid_argument(:writer_write, "batch schema does not match the writer")}

      true ->
        packed = Enum.map(schema.fields, &encode_stored(Map.get(columns, &1.name), rows, &1))

        if Enum.any?(packed, &match?({:error, _}, &1)) do
          Enum.find(packed, &match?({:error, _}, &1))
        else
          {:ok, [<<2, rows::unsigned-little-32>> | packed]}
        end
    end
  end

  defp rows_to_columns(fields, rows) do
    names = MapSet.new(fields, & &1.name)

    Enum.reduce_while(rows, {:ok, []}, fn row, {:ok, acc} ->
      case row_values(fields, names, row) do
        {:ok, values} -> {:cont, {:ok, [values | acc]}}
        {:error, %F3.Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reversed} ->
        columns =
          fields
          |> Enum.with_index()
          |> Enum.map(fn {field, index} ->
            values = Enum.map(reversed, &Enum.at(&1, index)) |> Enum.reverse()
            encode_logical(field.type, values)
          end)

        {:ok, columns}

      {:error, %F3.Error{}} = error ->
        error
    end
  end

  defp row_values(_fields, _names, row) when not is_map(row) do
    {:error, F3.Error.invalid_argument(:writer_write, "row must be a map")}
  end

  defp row_values(fields, names, row) do
    keys = MapSet.new(Map.keys(row), &key_name/1)

    if MapSet.subset?(keys, names) do
      take_fields(fields, row)
    else
      {:error, F3.Error.invalid_argument(:writer_write, "row has an unknown field")}
    end
  end

  defp take_fields(fields, row) do
    Enum.reduce_while(fields, {:ok, []}, fn field, {:ok, acc} ->
      case fetch_value(row, field) do
        {:ok, value} -> {:cont, {:ok, acc ++ [value]}}
        {:error, %F3.Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp fetch_value(row, field) do
    case lookup(row, field.name) do
      :missing when field.nullable ->
        {:ok, nil}

      :missing ->
        {:error, F3.Error.invalid_argument(:writer_write, "row is missing #{field.name}")}

      {:ok, nil} when field.nullable ->
        {:ok, nil}

      {:ok, nil} ->
        {:error, F3.Error.invalid_argument(:writer_write, "#{field.name} is not nullable")}

      {:ok, value} ->
        check_value(field.type, value)
    end
  end

  defp lookup(row, name) do
    if Map.has_key?(row, name) do
      {:ok, Map.fetch!(row, name)}
    else
      lookup_atom(row, name)
    end
  end

  defp lookup_atom(row, name) do
    Enum.find_value(row, :missing, fn
      {key, value} when is_atom(key) ->
        if Atom.to_string(key) == name, do: {:ok, value}

      _pair ->
        nil
    end)
  end

  defp key_name(key) when is_atom(key), do: Atom.to_string(key)
  defp key_name(key) when is_binary(key), do: key
  defp key_name(key), do: inspect(key)

  defp check_value({:list, child}, values) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case list_element(child, value) do
        {:ok, checked} -> {:cont, {:ok, acc ++ [checked]}}
        {:error, %F3.Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp check_value({:list, _child}, _value) do
    {:error, F3.Error.invalid_argument(:writer_write, "list value must be a list")}
  end

  defp check_value({:struct, fields}, row) when is_map(row) do
    names = MapSet.new(fields, & &1.name)

    case row_values(fields, names, row) do
      {:ok, values} ->
        {:ok, Map.new(Enum.zip(fields, values), fn {field, value} -> {field.name, value} end)}

      {:error, %F3.Error{}} = error ->
        error
    end
  end

  defp check_value({:struct, _fields}, _value) do
    {:error, F3.Error.invalid_argument(:writer_write, "struct value must be a map")}
  end

  defp check_value(type, value) do
    {:ok, kind} = type_kind(type)

    case check_primitive(kind, value) do
      {:ok, checked} -> {:ok, checked}
      :error -> primitive_error(kind, value)
    end
  end

  defp list_element(%{nullable: true}, nil), do: {:ok, nil}

  defp list_element(%{nullable: false}, nil) do
    {:error, F3.Error.invalid_argument(:writer_write, "list element is not nullable")}
  end

  defp list_element(child, value), do: check_value(child.type, value)

  defp check_primitive(:bool, value) when is_boolean(value), do: {:ok, value}

  defp check_primitive(:utf8, value) when is_binary(value) do
    if String.valid?(value), do: {:ok, value}, else: :error
  end

  defp check_primitive(kind, value)
       when kind in [:i64, :i32, :u64, :u32, :u16, :u8] and is_integer(value) do
    {signed, width} = integer_shape(kind)
    {min, max} = integer_bounds(width, signed)
    if value >= min and value <= max, do: {:ok, value}, else: :error
  end

  defp check_primitive(kind, value) when kind in [:f64, :f32] and is_number(value),
    do: {:ok, value / 1}

  defp check_primitive(_kind, _value), do: :error

  defp primitive_error(:utf8, value) when is_binary(value) do
    {:error, F3.Error.invalid_argument(:writer_write, "string is not UTF-8")}
  end

  defp primitive_error(kind, value)
       when kind in [:i64, :i32, :u64, :u32, :u16, :u8] and is_integer(value) do
    {:error, F3.Error.invalid_type(:writer_write, "#{kind} value is outside the field width")}
  end

  defp primitive_error(kind, _value) do
    {:error, F3.Error.invalid_argument(:writer_write, "value does not match #{kind}")}
  end

  defp integer_shape(:i64), do: {true, 64}
  defp integer_shape(:i32), do: {true, 32}
  defp integer_shape(:u64), do: {false, 64}
  defp integer_shape(:u32), do: {false, 32}
  defp integer_shape(:u16), do: {false, 16}
  defp integer_shape(:u8), do: {false, 8}

  defp integer_bounds(width, true) do
    limit = Bitwise.bsl(1, width - 1)
    {-limit, limit - 1}
  end

  defp integer_bounds(width, false) do
    {0, Bitwise.bsl(1, width) - 1}
  end

  defp encode_logical(type, values) do
    [validity_blob(values), encode_body(type, values)]
  end

  defp validity_blob(values) do
    if Enum.any?(values, &is_nil/1) do
      bytes = validity_bytes(values)
      <<byte_size(bytes)::unsigned-little-32, bytes::binary>>
    else
      <<0::unsigned-little-32>>
    end
  end

  defp validity_bytes(values) do
    Enum.map_join(values, fn
      nil -> <<0>>
      _value -> <<1>>
    end)
  end

  defp native_build? do
    stamp = Path.expand("../../native/f3_native/.f3_build_native", __DIR__)
    File.read(stamp) == {:ok, "1"}
  end

  defp encode_body(:bool, values) do
    Enum.map_join(values, fn
      true -> <<1>>
      _other -> <<0>>
    end)
  end

  defp encode_body(:utf8, values) do
    parts =
      Enum.map(values, fn
        nil -> <<0::unsigned-little-32>>
        text -> <<byte_size(text)::unsigned-little-32, text::binary>>
      end)

    [<<length(values)::unsigned-little-32>> | parts]
  end

  defp encode_body({:int, _, _} = type, values), do: encode_numbers(type, values)
  defp encode_body({:float, _} = type, values), do: encode_numbers(type, values)

  defp encode_body({:list, child}, values) do
    {offsets, flat} =
      Enum.reduce(values, {[0], []}, fn
        nil, {offsets, flat} -> {offsets ++ [List.last(offsets)], flat}
        items, {offsets, flat} -> {offsets ++ [List.last(offsets) + length(items)], flat ++ items}
      end)

    [<<4>>, Enum.map(offsets, &<<&1::signed-little-32>>), encode_logical(child.type, flat)]
  end

  defp encode_body({:struct, fields}, values) do
    Enum.map(fields, fn field ->
      child_values =
        Enum.map(values, fn
          nil -> empty_of(field.type)
          row -> Map.fetch!(row, field.name)
        end)

      encode_logical(field.type, child_values)
    end)
  end

  defp encode_numbers(type, values) do
    {:ok, kind} = type_kind(type)
    width = @widths[kind] * 8

    Enum.map_join(values, fn
      nil -> <<0::size(width)>>
      value when kind in [:f64, :f32] -> float_bits(kind, value)
      value -> integer_bits(kind, value, width)
    end)
  end

  defp integer_bits(kind, value, width) when kind in [:i64, :i32],
    do: <<value::signed-little-size(width)>>

  defp integer_bits(_kind, value, width), do: <<value::unsigned-little-size(width)>>
  defp float_bits(:f64, value), do: <<value::float-little-64>>
  defp float_bits(:f32, value), do: <<value::float-little-32>>

  defp empty_of({:list, _}), do: []
  defp empty_of({:struct, fields}), do: Map.new(fields, &{&1.name, empty_of(&1.type)})
  defp empty_of(:bool), do: false
  defp empty_of(:utf8), do: ""
  defp empty_of({:float, _}), do: 0.0
  defp empty_of(_type), do: 0

  defp encode_stored(nil, _rows, _field) do
    {:error, F3.Error.invalid_argument(:writer_write, "batch is missing a column")}
  end

  defp encode_stored(%F3.Column{num_rows: rows} = column, rows, field) do
    case stored_kind(column, field.type) do
      :ok ->
        [stored_validity(column), stored_body(column)]

      :error ->
        {:error, F3.Error.invalid_type(:writer_write, "column kind does not match the schema")}
    end
  end

  defp encode_stored(%F3.Column{}, _rows, _field) do
    {:error,
     F3.Error.invalid_argument(:writer_write, "column row count does not match the batch")}
  end

  defp stored_kind(%F3.Column{kind: kind}, type) do
    case type_kind(type) do
      {:ok, ^kind} -> :ok
      {:ok, :list} when kind == :list32 -> :ok
      _other -> :error
    end
  end

  defp stored_validity(%F3.Column{validity: nil}), do: <<0::unsigned-little-32>>

  defp stored_validity(%F3.Column{validity: validity}) do
    <<byte_size(validity)::unsigned-little-32, validity::binary>>
  end

  defp stored_body(%F3.Column{kind: :utf8, values: values}) do
    parts = Enum.map(values, &<<byte_size(&1)::unsigned-little-32, &1::binary>>)
    [<<length(values)::unsigned-little-32>> | parts]
  end

  defp stored_body(%F3.Column{kind: :list32, values: offsets, child: child}) do
    [<<4>>, offsets, encode_stored_child(child)]
  end

  defp stored_body(%F3.Column{kind: :struct, children: children}) do
    Enum.map(children, &encode_stored_child/1)
  end

  defp stored_body(%F3.Column{values: values}) when is_binary(values), do: values

  defp encode_stored_child(%F3.Column{} = column) do
    [stored_validity(column), stored_body(column)]
  end

  defp command(%{port: port}, frame) do
    if Port.info(port) == nil do
      {:error, F3.Error.io(:writer, :ewrite, %{})}
    else
      Port.command(port, frame)

      receive do
        {^port, {:data, "ok"}} -> :ok
        {^port, {:data, data}} -> {:error, helper_error(data)}
        {^port, {:exit_status, _code}} -> {:error, F3.Error.io(:writer, :ewrite, %{})}
      after
        180_000 -> {:error, F3.Error.io(:writer, :etimedout, %{})}
      end
    end
  rescue
    ArgumentError -> {:error, F3.Error.io(:writer, :ewrite, %{})}
  end

  defp helper_error(data) do
    cond do
      String.contains?(data, "finish failed") ->
        F3.Error.io(:writer_close, :efailed, %{})

      String.contains?(data, "resource limit") ->
        F3.Error.resource_limit(:writer, "writer frame is above 64 MiB", %{})

      true ->
        F3.Error.io(:writer, :ewrite, %{})
    end
  end

  defp finish(%__MODULE__{} = writer, flag) do
    case command(writer, <<3, flag>>) do
      :ok ->
        stop_port(writer.port)

        case File.rename(writer.temp, writer.path) do
          :ok ->
            {:ok, %{writer | port: nil, temp: nil, closed: true}}

          {:error, reason} ->
            File.rm(writer.temp)
            {:error, F3.Error.io(:writer_close, reason, %{path: writer.path})}
        end

      {:error, %F3.Error{}} = error ->
        stop_port(writer.port)
        File.rm(writer.temp)
        error
    end
  end

  defp stop_port(nil), do: :ok

  defp stop_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  end
end
