defmodule F3.Column do
  @moduledoc """
  One columnar vector owned by Elixir.

  Primitive values are little-endian binaries. UTF-8 values are a list of
  binaries. Booleans are a binary of bytes `0` and `1`. List columns store
  little-endian offsets of length `num_rows + 1` and one child column.
  Struct columns store child columns and a validity binary of bytes `0`
  and `1`. `validity` is `nil` when every row is present. A `0` byte means
  null. These terms are what `F3.Batch` stores. `F3.Batch.to_rows/1` is the
  convenience conversion.
  """

  @enforce_keys [:kind, :num_rows, :values]
  defstruct [:kind, :num_rows, :values, :validity, :child, :children, :names]

  @type kind ::
          :i64
          | :i32
          | :u64
          | :u32
          | :u16
          | :u8
          | :f64
          | :f32
          | :bool
          | :utf8
          | :list32
          | :list64
          | :struct

  @typedoc """
  One column.

  `kind` selects the physical layout. `num_rows` is the logical row count.
  `values` holds little-endian scalars, UTF-8 binaries, or list offsets.
  `validity` is `nil` when every row is present, otherwise one byte per row.
  `child` is the list element column. `children` and `names` are the struct
  fields, in the same order.
  """
  @type t :: %__MODULE__{
          kind: kind(),
          num_rows: non_neg_integer(),
          values: binary() | [binary()] | nil,
          validity: binary() | nil,
          child: t() | nil,
          children: [t()] | nil,
          names: [String.t()] | nil
        }

  @widths %{i64: 8, i32: 4, u64: 8, u32: 4, u16: 2, u8: 1, f64: 8, f32: 4, bool: 1}
  @integers [:i64, :i32, :u64, :u32, :u16, :u8]
  @numbers @integers ++ [:f64, :f32]

  @doc """
  Builds a column from the native decoder term.

  `kind` is a primitive, `:bool`, `:utf8`, `:list32`, or `:list64`. `rows`
  is the logical row count. `values` is the payload for that kind. `validity`
  is `nil` or one byte per row, where `0` is null. A bad shape returns
  `{:error, %F3.Error{category: :corrupt}}` and does not raise.

  ## Examples

      iex> {:ok, column} = F3.Column.from_native(:i64, 2, <<1::little-64, 2::little-64>>, nil)
      iex> F3.Column.value(column, 1)
      2

      iex> {:error, error} = F3.Column.from_native(:nope, 0, <<>>, nil)
      iex> error.category
      :corrupt
  """
  @spec from_native(atom(), non_neg_integer(), term(), binary() | nil) ::
          {:ok, t()} | {:error, F3.Error.t()}
  def from_native(kind, rows, values, validity)
      when is_atom(kind) and is_integer(rows) and rows >= 0 do
    with :ok <- known_kind(kind),
         :ok <- check_validity(validity, rows),
         :ok <- check_values(kind, rows, values) do
      {:ok,
       %__MODULE__{
         kind: kind,
         num_rows: rows,
         values: normalize_values(kind, values),
         validity: normalize_validity(validity),
         children: [],
         child: nil,
         names: nil
       }}
    end
  end

  def from_native(_kind, _rows, _values, _validity) do
    {:error, F3.Error.corrupt(:decode, "native column term is the wrong shape")}
  end

  @doc """
  An empty column of a primitive, boolean, UTF-8, or list kind.
  An unknown kind raises `FunctionClauseError`.

  ## Examples

      iex> F3.Column.empty(:i64).num_rows
      0

      iex> F3.Column.empty(:utf8).values
      []
  """
  @spec empty(kind()) :: t()
  def empty(:utf8) do
    %__MODULE__{kind: :utf8, num_rows: 0, values: [], children: []}
  end

  def empty(:list32) do
    %__MODULE__{kind: :list32, num_rows: 0, values: <<0::signed-little-32>>, children: []}
  end

  def empty(:list64) do
    %__MODULE__{kind: :list64, num_rows: 0, values: <<0::signed-little-64>>, children: []}
  end

  def empty(kind) when is_map_key(@widths, kind) do
    %__MODULE__{kind: kind, num_rows: 0, values: <<>>, children: []}
  end

  @doc """
  Struct column. `names` are the child field names. `flags` is the boolean
  physical column. A false or null flag makes that struct null. `children`
  must have the same row count as `flags`. A mismatch is `:corrupt`.

  ## Examples

      iex> {:ok, flags} = F3.Column.from_native(:bool, 1, <<1>>, nil)
      iex> {:ok, id} = F3.Column.from_native(:i64, 1, <<7::little-64>>, nil)
      iex> {:ok, column} = F3.Column.struct(["id"], flags, [id])
      iex> F3.Column.value(column, 0)
      %{"id" => 7}
  """
  @spec struct([String.t()], t(), [t()]) :: {:ok, t()} | {:error, F3.Error.t()}
  def struct(names, %__MODULE__{kind: :bool, num_rows: rows} = flags, children)
      when is_list(names) and length(names) == length(children) do
    if Enum.all?(children, &(&1.num_rows == rows)) do
      {:ok,
       %__MODULE__{
         kind: :struct,
         num_rows: rows,
         values: nil,
         names: names,
         children: children,
         validity: struct_flags(flags)
       }}
    else
      {:error, F3.Error.corrupt(:read, "struct child row count does not match")}
    end
  end

  def struct(_names, _flags, _children) do
    {:error, F3.Error.corrupt(:read, "struct validity is not a boolean column")}
  end

  @doc """
  List column from an offset vector and its child values.

  `offsets` is `:list32` or `:list64` with `num_rows + 1` offsets. The last
  offset must equal `child.num_rows`. A mismatch is `:corrupt`.

  ## Examples

      iex> offsets = <<0::little-32, 1::little-32>>
      iex> {:ok, parent} = F3.Column.from_native(:list32, 1, offsets, nil)
      iex> {:ok, child} = F3.Column.from_native(:i64, 1, <<4::little-64>>, nil)
      iex> {:ok, column} = F3.Column.list(parent, child)
      iex> F3.Column.value(column, 0)
      [4]
  """
  @spec list(t(), t()) :: {:ok, t()} | {:error, F3.Error.t()}
  def list(%__MODULE__{kind: kind, num_rows: rows, values: offsets} = parent, child)
      when kind in [:list32, :list64] do
    points = read_offsets(kind, offsets)

    cond do
      length(points) != rows + 1 ->
        {:error, F3.Error.corrupt(:read, "list offset length does not match")}

      List.last(points) != child.num_rows ->
        {:error, F3.Error.corrupt(:read, "list values do not match the offsets")}

      true ->
        {:ok,
         %__MODULE__{
           kind: kind,
           num_rows: rows,
           values: offsets,
           validity: parent.validity,
           child: child,
           children: []
         }}
    end
  end

  def list(_offsets, _child) do
    {:error, F3.Error.corrupt(:read, "list offsets are not a list column")}
  end

  @doc """
  Whether `column` has the kind a logical field asked for.
  `:integer` accepts any integer width. That is the dictionary index path.
  Any other kind must match exactly. This returns a boolean and does not raise
  for a column.

  ## Examples

      iex> {:ok, column} = F3.Column.from_native(:i32, 0, <<>>, nil)
      iex> F3.Column.matches?(column, :integer)
      true
      iex> F3.Column.matches?(column, :i64)
      false
  """
  @spec matches?(t(), atom()) :: boolean()
  def matches?(%__MODULE__{kind: kind}, :integer) when kind in @integers, do: true
  def matches?(%__MODULE__{kind: kind}, kind), do: true
  def matches?(%__MODULE__{}, _kind), do: false

  @doc """
  Appends two columns of the same kind along the row axis.
  `nil` on the left returns the right column. Different kinds are `:corrupt`.

  ## Examples

      iex> {:ok, left} = F3.Column.from_native(:i64, 1, <<1::little-64>>, nil)
      iex> {:ok, right} = F3.Column.from_native(:i64, 1, <<2::little-64>>, nil)
      iex> {:ok, both} = F3.Column.concat(left, right)
      iex> F3.Column.value(both, 1)
      2
      iex> {:ok, column} = F3.Column.concat(nil, right)
      iex> column.num_rows
      1
  """
  @spec concat(t() | nil, t()) :: {:ok, t()} | {:error, F3.Error.t()}
  def concat(nil, %__MODULE__{} = column), do: {:ok, column}

  def concat(%__MODULE__{kind: kind} = left, %__MODULE__{kind: kind} = right) do
    concat_same(left, right)
  end

  def concat(%__MODULE__{}, %__MODULE__{}) do
    {:error, F3.Error.corrupt(:read, "cannot concatenate different column kinds")}
  end

  @doc """
  Rows `start` through `start + length`, exclusive of the end.
  The range must fit in the column. A range past the end raises
  `FunctionClauseError`.

  ## Examples

      iex> {:ok, column} = F3.Column.from_native(:i64, 2, <<1::little-64, 2::little-64>>, nil)
      iex> sliced = F3.Column.slice(column, 1, 1)
      iex> F3.Column.value(sliced, 0)
      2
  """
  @spec slice(t(), non_neg_integer(), non_neg_integer()) :: t()
  def slice(%__MODULE__{num_rows: rows} = column, start, length)
      when is_integer(start) and is_integer(length) and start >= 0 and length >= 0 and
             start + length <= rows do
    slice_kind(column, start, length)
  end

  @doc """
  The Elixir value of row `index`.

  Integers and floats are numbers. Booleans are `true` or `false`. UTF-8 is
  a binary. A struct is a map. A list is a list. A null row is `nil`.
  An index past the column is not checked and may raise.

  ## Examples

      iex> {:ok, column} = F3.Column.from_native(:i64, 1, <<9::little-64>>, <<0>>)
      iex> F3.Column.value(column, 0)
      nil
  """
  @spec value(t(), non_neg_integer()) :: term()
  def value(%__MODULE__{kind: :utf8, values: values, validity: validity}, index) do
    if present?(validity, index), do: Enum.at(values, index), else: nil
  end

  def value(%__MODULE__{kind: :bool, values: values, validity: validity}, index) do
    if present?(validity, index), do: :binary.at(values, index) == 1, else: nil
  end

  def value(
        %__MODULE__{kind: :struct, names: names, children: children, validity: validity},
        index
      ) do
    if present?(validity, index) do
      Map.new(Enum.zip(names, children), fn {name, child} -> {name, value(child, index)} end)
    else
      nil
    end
  end

  def value(%__MODULE__{kind: kind, values: offsets, child: child, validity: validity}, index)
      when kind in [:list32, :list64] do
    if present?(validity, index) do
      points = read_offsets(kind, offsets)
      first = Enum.at(points, index)
      last = Enum.at(points, index + 1)
      Enum.map(first..(last - 1)//1, &value(child, &1))
    else
      nil
    end
  end

  def value(%__MODULE__{kind: kind, values: values, validity: validity}, index)
      when kind in @numbers do
    if present?(validity, index), do: number_at(kind, values, index), else: nil
  end

  @doc """
  Replaces each index with the dictionary value at that position.

  `index` must be an integer column. An index past `dict` is `:corrupt`.
  This does not raise for a well-formed column.

  ## Examples

      iex> values = <<10::little-64, 20::little-64>>
      iex> {:ok, dict} = F3.Column.from_native(:i64, 2, values, nil)
      iex> {:ok, index} = F3.Column.from_native(:i32, 2, <<1::little-32, 0::little-32>>, nil)
      iex> {:ok, taken} = F3.Column.gather(dict, index)
      iex> F3.Column.value(taken, 0)
      20
  """
  @spec gather(t(), t()) :: {:ok, t()} | {:error, F3.Error.t()}
  def gather(%__MODULE__{} = dict, %__MODULE__{} = index) do
    with true <- matches?(index, :integer),
         ints <- integers(index),
         {:ok, taken} <- take_indexed(dict, ints, index.validity) do
      pack_gathered(dict.kind, taken)
    else
      false -> {:error, F3.Error.corrupt(:read, "dictionary indexes are not integers")}
      {:error, %F3.Error{}} = error -> error
    end
  end

  defp concat_same(%__MODULE__{kind: :utf8} = left, right) do
    {:ok,
     %{
       left
       | num_rows: left.num_rows + right.num_rows,
         values: left.values ++ right.values,
         validity: join_validity(left, right)
     }}
  end

  defp concat_same(%__MODULE__{kind: :struct} = left, right) do
    children = Enum.zip(left.children, right.children)

    with {:ok, children} <- concat_pairs(children) do
      {:ok,
       %{
         left
         | num_rows: left.num_rows + right.num_rows,
           children: children,
           validity: join_validity(left, right)
       }}
    end
  end

  defp concat_same(%__MODULE__{kind: kind, child: nil} = left, %__MODULE__{child: nil} = right)
       when kind in [:list32, :list64] do
    {:ok,
     %{
       left
       | num_rows: left.num_rows + right.num_rows,
         values: join_offsets(kind, left.values, right.values),
         validity: join_validity(left, right)
     }}
  end

  defp concat_same(%__MODULE__{kind: kind} = left, right) when kind in [:list32, :list64] do
    with {:ok, child} <- concat(left.child, right.child) do
      {:ok,
       %{
         left
         | num_rows: left.num_rows + right.num_rows,
           values: join_offsets(kind, left.values, right.values),
           child: child,
           validity: join_validity(left, right)
       }}
    end
  end

  defp concat_same(%__MODULE__{} = left, right) do
    {:ok,
     %{
       left
       | num_rows: left.num_rows + right.num_rows,
         values: left.values <> right.values,
         validity: join_validity(left, right)
     }}
  end

  defp concat_pairs(pairs) do
    Enum.reduce_while(pairs, {:ok, []}, fn {left, right}, {:ok, acc} ->
      case concat(left, right) do
        {:ok, column} -> {:cont, {:ok, [column | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, columns} -> {:ok, Enum.reverse(columns)}
      error -> error
    end
  end

  defp slice_kind(%__MODULE__{kind: :utf8} = column, start, length) do
    %{
      column
      | num_rows: length,
        values: Enum.slice(column.values, start, length),
        validity: slice_validity(column.validity, start, length)
    }
  end

  defp slice_kind(%__MODULE__{kind: :struct} = column, start, length) do
    %{
      column
      | num_rows: length,
        children: Enum.map(column.children, &slice(&1, start, length)),
        validity: slice_validity(column.validity, start, length)
    }
  end

  defp slice_kind(%__MODULE__{kind: kind} = column, start, length)
       when kind in [:list32, :list64] do
    points = read_offsets(kind, column.values)
    first = Enum.at(points, start)
    last = Enum.at(points, start + length)
    sliced = Enum.slice(points, start, length + 1)
    rebased = Enum.map(sliced, &(&1 - first))

    %{
      column
      | num_rows: length,
        values: write_offsets(kind, rebased),
        child: slice(column.child, first, last - first),
        validity: slice_validity(column.validity, start, length)
    }
  end

  defp slice_kind(%__MODULE__{kind: kind} = column, start, length) do
    width = Map.fetch!(@widths, kind)

    %{
      column
      | num_rows: length,
        values: binary_part(column.values, start * width, length * width),
        validity: slice_validity(column.validity, start, length)
    }
  end

  defp take_indexed(dict, ints, validity) do
    ints
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {int, index}, {:ok, acc} ->
      take_one(dict, int, present?(validity, index), acc)
    end)
    |> case do
      {:ok, acc} -> {:ok, Enum.reverse(acc)}
      error -> error
    end
  end

  defp take_one(_dict, _int, false, acc), do: {:cont, {:ok, [nil | acc]}}

  defp take_one(dict, int, true, acc) when int >= 0 and int < dict.num_rows do
    {:cont, {:ok, [value(dict, int) | acc]}}
  end

  defp take_one(_dict, _int, true, _acc) do
    {:halt, {:error, F3.Error.corrupt(:read, "dictionary index is out of range")}}
  end

  defp pack_gathered(kind, values) do
    validity = values |> Enum.map(&if(is_nil(&1), do: 0, else: 1)) |> :binary.list_to_bin()

    {:ok,
     %__MODULE__{
       kind: kind,
       num_rows: length(values),
       values: pack_values(kind, values),
       validity: normalize_validity(validity),
       children: [],
       child: nil
     }}
  end

  defp pack_values(:utf8, values) do
    Enum.map(values, fn
      nil -> ""
      binary when is_binary(binary) -> binary
    end)
  end

  defp pack_values(:bool, values) do
    values
    |> Enum.map(fn
      true -> 1
      false -> 0
      nil -> 0
    end)
    |> :binary.list_to_bin()
  end

  defp pack_values(kind, values) when kind in @numbers do
    Enum.reduce(values, <<>>, fn value, acc -> acc <> pack_number(kind, value || 0) end)
  end

  defp integers(%__MODULE__{kind: kind, values: values, num_rows: rows}) when kind in @integers do
    for index <- 0..(rows - 1)//1, do: number_at(kind, values, index)
  end

  defp number_at(:i64, values, index), do: signed_at(values, index, 64)
  defp number_at(:i32, values, index), do: signed_at(values, index, 32)
  defp number_at(:u64, values, index), do: unsigned_at(values, index, 64)
  defp number_at(:u32, values, index), do: unsigned_at(values, index, 32)
  defp number_at(:u16, values, index), do: unsigned_at(values, index, 16)
  defp number_at(:u8, values, index), do: unsigned_at(values, index, 8)
  defp number_at(:f64, values, index), do: float_at(values, index, 64)
  defp number_at(:f32, values, index), do: float_at(values, index, 32)

  defp signed_at(values, index, width) do
    <<n::signed-little-size(^width)>> = binary_part(values, div(index * width, 8), div(width, 8))
    n
  end

  defp unsigned_at(values, index, width) do
    <<n::unsigned-little-size(^width)>> =
      binary_part(values, div(index * width, 8), div(width, 8))

    n
  end

  defp float_at(values, index, width) do
    <<n::float-little-size(^width)>> = binary_part(values, div(index * width, 8), div(width, 8))
    n
  end

  defp pack_number(:i64, n), do: <<n::signed-little-64>>
  defp pack_number(:i32, n), do: <<n::signed-little-32>>
  defp pack_number(:u64, n), do: <<n::unsigned-little-64>>
  defp pack_number(:u32, n), do: <<n::unsigned-little-32>>
  defp pack_number(:u16, n), do: <<n::unsigned-little-16>>
  defp pack_number(:u8, n), do: <<n::unsigned-little-8>>
  defp pack_number(:f64, n), do: <<n::float-little-64>>
  defp pack_number(:f32, n), do: <<n::float-little-32>>

  defp struct_flags(%__MODULE__{num_rows: rows, values: values, validity: validity}) do
    bytes =
      for index <- 0..(rows - 1)//1 do
        if present?(validity, index) and :binary.at(values, index) == 1, do: 1, else: 0
      end

    bytes |> :binary.list_to_bin() |> normalize_validity()
  end

  defp join_offsets(kind, left, right) do
    points = read_offsets(kind, left)
    base = List.last(points)
    shifted = kind |> offset_tail(right, base)
    write_offsets(kind, points ++ shifted)
  end

  defp offset_tail(kind, bytes, base) do
    bytes |> then_offsets(kind) |> tl() |> Enum.map(&(&1 + base))
  end

  defp then_offsets(bytes, kind), do: read_offsets(kind, bytes)

  defp read_offsets(:list32, <<>>), do: []

  defp read_offsets(:list32, bytes) do
    for <<n::signed-little-32 <- bytes>>, do: n
  end

  defp read_offsets(:list64, bytes) do
    for <<n::signed-little-64 <- bytes>>, do: n
  end

  defp write_offsets(:list32, points) do
    Enum.reduce(points, <<>>, fn n, acc -> acc <> <<n::signed-little-32>> end)
  end

  defp write_offsets(:list64, points) do
    Enum.reduce(points, <<>>, fn n, acc -> acc <> <<n::signed-little-64>> end)
  end

  defp join_validity(%{validity: nil, num_rows: _rows}, %{validity: nil}), do: nil

  defp join_validity(left, right) do
    normalize_validity(validity_bytes(left) <> validity_bytes(right))
  end

  defp validity_bytes(%{validity: nil, num_rows: rows}), do: :binary.copy(<<1>>, rows)
  defp validity_bytes(%{validity: bytes}), do: bytes

  defp slice_validity(nil, _start, _length), do: nil

  defp slice_validity(bytes, start, length) do
    bytes |> binary_part(start, length) |> normalize_validity()
  end

  defp present?(nil, _index), do: true
  defp present?(bytes, index), do: :binary.at(bytes, index) == 1

  defp known_kind(kind) when kind in @numbers or kind in [:bool, :utf8, :list32, :list64], do: :ok

  defp known_kind(_kind) do
    {:error, F3.Error.corrupt(:decode, "native column kind is not supported")}
  end

  defp check_validity(nil, _rows), do: :ok

  defp check_validity(bytes, rows) when is_binary(bytes) and byte_size(bytes) == rows do
    if bytes |> :binary.bin_to_list() |> Enum.all?(&(&1 in [0, 1])) do
      :ok
    else
      {:error, F3.Error.corrupt(:decode, "validity bytes must be 0 or 1")}
    end
  end

  defp check_validity(_bytes, _rows) do
    {:error, F3.Error.corrupt(:decode, "validity length does not match the row count")}
  end

  defp check_values(:utf8, rows, values) when is_list(values) and length(values) == rows do
    if Enum.all?(values, &is_binary/1) do
      :ok
    else
      {:error, F3.Error.corrupt(:decode, "utf8 values must be binaries")}
    end
  end

  defp check_values(kind, rows, values)
       when kind in [:list32, :list64] and is_binary(values) do
    width = if kind == :list32, do: 4, else: 8

    if byte_size(values) == (rows + 1) * width do
      :ok
    else
      {:error, F3.Error.corrupt(:decode, "list offset binary has the wrong length")}
    end
  end

  defp check_values(kind, rows, values) when is_map_key(@widths, kind) and is_binary(values) do
    if byte_size(values) == rows * Map.fetch!(@widths, kind) do
      :ok
    else
      {:error, F3.Error.corrupt(:decode, "value binary has the wrong length")}
    end
  end

  defp check_values(_kind, _rows, _values) do
    {:error, F3.Error.corrupt(:decode, "value payload does not match the column kind")}
  end

  defp normalize_values(:utf8, values), do: values
  defp normalize_values(_kind, values), do: values

  defp normalize_validity(nil), do: nil

  defp normalize_validity(bytes) do
    if bytes |> :binary.bin_to_list() |> Enum.all?(&(&1 == 1)), do: nil, else: bytes
  end
end
