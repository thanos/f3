defmodule F3.FlatBuffer do
  @moduledoc """
  Bounded reader for the FlatBuffers tables this library needs.

  Offsets are checked against the buffer before every read. A table that
  points at itself stops at a depth or visit cap and returns `:depth`
  rather than looping. This is not a general FlatBuffers toolkit. Field
  numbers are the positions in the pinned `File.fbs` and in Arrow IPC 53.
  """

  @max_depth 32
  @max_visits 10_000
  @max_vector 1_000_000

  @enforce_keys [:bin, :pos, :vtable, :vtable_size, :object_size, :depth, :visits]
  defstruct [:bin, :pos, :vtable, :vtable_size, :object_size, :depth, :visits]

  @typedoc """
  One open table.

  `bin` is the whole buffer. `pos` is the table's start. `vtable` is the
  vtable start. `vtable_size` and `object_size` come from that vtable.
  `depth` counts nested tables. `visits` counts tables opened from this root.
  """
  @type t :: %__MODULE__{
          bin: binary(),
          pos: non_neg_integer(),
          vtable: non_neg_integer(),
          vtable_size: pos_integer(),
          object_size: pos_integer(),
          depth: non_neg_integer(),
          visits: non_neg_integer()
        }

  @typedoc "`:corrupt` is a bad offset. `:depth` is the visit or nesting cap."
  @type error :: :corrupt | :depth

  @doc """
  Opens the root table. The first four bytes are a little-endian offset
  from the start of `bin`. An empty or non-binary buffer is `:corrupt`.
  This does not raise for those inputs.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> table.pos
      10

      iex> F3.FlatBuffer.root(<<>>)
      {:error, :corrupt}
  """
  @spec root(binary()) :: {:ok, t()} | {:error, error()}
  def root(bin) when is_binary(bin) do
    Process.put(:f3_flat_buffer_visits, 0)

    with {:ok, offset} <- u32(bin, 0),
         :ok <- nonzero(offset),
         :ok <- fits(bin, offset, 4) do
      open_table(bin, offset, 0)
    end
  end

  def root(_bin), do: {:error, :corrupt}

  @doc """
  Signed or unsigned little-endian scalar. An absent slot returns `default`.

  `index` is the vtable field, starting at 0. `kind` is `:u8`, `:u16`,
  `:u32`, `:u64`, `:i16`, `:i32`, or `:bool`. A bad offset is `:corrupt`.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.scalar(table, 0, :u8, 0)
      {:ok, 7}
      iex> F3.FlatBuffer.scalar(table, 1, :u8, 0)
      {:ok, 0}
  """
  @spec scalar(t(), non_neg_integer(), :u8 | :u16 | :u32 | :u64 | :i16 | :i32 | :bool, term()) ::
          {:ok, term()} | {:error, error()}
  def scalar(%__MODULE__{} = table, index, kind, default) do
    case optional_scalar(table, index, kind) do
      {:ok, nil} -> {:ok, default}
      other -> other
    end
  end

  @doc """
  Same as `scalar/4`, but an absent slot is `nil` instead of a default.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.optional_scalar(table, 1, :u8)
      {:ok, nil}
  """
  @spec optional_scalar(t(), non_neg_integer(), :u8 | :u16 | :u32 | :u64 | :i16 | :i32 | :bool) ::
          {:ok, term() | nil} | {:error, error()}
  def optional_scalar(%__MODULE__{} = table, index, kind) do
    case slot(table, index) do
      :absent ->
        {:ok, nil}

      {:ok, offset} ->
        width = scalar_width(kind)

        with :ok <- inside_object(table, offset, width),
             :ok <- fits(table.bin, table.pos + offset, width) do
          read_scalar(table.bin, table.pos + offset, kind)
        end
    end
  end

  @doc """
  UTF-8 string. Absent is `nil`. Bytes that are not UTF-8 are `:corrupt`.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.string(table, 1)
      {:ok, nil}
  """
  @spec string(t(), non_neg_integer()) :: {:ok, String.t() | nil} | {:error, error()}
  def string(%__MODULE__{} = table, index) do
    case bytes(table, index) do
      {:ok, nil} ->
        {:ok, nil}

      {:ok, raw} ->
        if String.valid?(raw), do: {:ok, raw}, else: {:error, :corrupt}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Raw byte vector, including an Arrow IPC message. Absent is `nil`.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.bytes(table, 1)
      {:ok, nil}
  """
  @spec bytes(t(), non_neg_integer()) :: {:ok, binary() | nil} | {:error, error()}
  def bytes(%__MODULE__{} = table, index) do
    case vector_start(table, index) do
      :absent ->
        {:ok, nil}

      {:ok, start, len} ->
        with :ok <- fits(table.bin, start + 4, len) do
          {:ok, binary_part(table.bin, start + 4, len)}
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Vector of unsigned little-endian integers. Absent is an empty list.
  `width` is 4 or 8. Any other width raises `FunctionClauseError`.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.uints(table, 1, 4)
      {:ok, []}
  """
  @spec uints(t(), non_neg_integer(), 4 | 8) :: {:ok, [non_neg_integer()]} | {:error, error()}
  def uints(%__MODULE__{} = table, index, width) when width in [4, 8] do
    case vector_body(table, index, width) do
      :absent ->
        {:ok, []}

      {:ok, body, len} ->
        {:ok, read_uints(body, len, width)}

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Vector of tables. Absent is an empty list.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.tables(table, 1)
      {:ok, []}
  """
  @spec tables(t(), non_neg_integer()) :: {:ok, [t()]} | {:error, error()}
  def tables(%__MODULE__{} = table, index) do
    case vector_start(table, index) do
      :absent ->
        {:ok, []}

      {:ok, start, len} ->
        base = start + 4

        with :ok <- fits(table.bin, base, len * 4) do
          read_tables(table, base, len)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Vector of UTF-8 strings. Absent is an empty list.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.string_vector(table, 1)
      {:ok, []}
  """
  @spec string_vector(t(), non_neg_integer()) :: {:ok, [String.t()]} | {:error, error()}
  def string_vector(%__MODULE__{} = table, index) do
    case vector_start(table, index) do
      :absent ->
        {:ok, []}

      {:ok, start, 0} ->
        _ = start
        {:ok, []}

      {:ok, start, len} ->
        base = start + 4

        with :ok <- fits(table.bin, base, len * 4) do
          read_strings(table.bin, base, len)
        end

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Follows a table slot. Absent is `nil`. A slot that does not point at a
  table is `:corrupt`.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 7, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.table(table, 1)
      {:ok, nil}
  """
  @spec table(t(), non_neg_integer()) :: {:ok, t() | nil} | {:error, error()}
  def table(%__MODULE__{} = table, index) do
    case follow_slot(table, index) do
      :absent ->
        {:ok, nil}

      {:ok, pos} ->
        open_table(table.bin, pos, table.depth + 1)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Union stored as a type byte at `type_index` and a table at the next slot.

  Type `0` is none. Any other type follows the table. The caller interprets
  the type byte. A non-zero type with no table is `:corrupt`.

  ## Examples

      iex> bin = <<10::little-32, 6::little-16, 8::little-16, 4::little-16, 6::little-32, 0, 0, 0, 0>>
      iex> {:ok, table} = F3.FlatBuffer.root(bin)
      iex> F3.FlatBuffer.union(table, 0)
      {:ok, :none}
  """
  @spec union(t(), non_neg_integer()) ::
          {:ok, :none | {non_neg_integer(), t()}} | {:error, error()}
  def union(%__MODULE__{} = table, type_index) do
    with {:ok, type} <- scalar(table, type_index, :u8, 0) do
      union_value(table, type_index, type)
    end
  end

  defp union_value(_table, _type_index, 0), do: {:ok, :none}

  defp union_value(table, type_index, type) do
    case table(table, type_index + 1) do
      {:ok, nil} -> {:error, :corrupt}
      {:ok, child} -> {:ok, {type, child}}
      {:error, _} = error -> error
    end
  end

  defp read_strings(_bin, _base, 0), do: {:ok, []}

  defp read_strings(bin, base, len) do
    0..(len - 1)//1
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, acc} ->
      read_one_string(bin, base + index * 4, acc)
    end)
    |> reverse_ok()
  end

  defp read_one_string(bin, at, acc) do
    with {:ok, pos} <- follow(bin, at),
         {:ok, text} <- read_string_at(bin, pos) do
      {:cont, {:ok, [text | acc]}}
    else
      {:error, _} = error -> {:halt, error}
    end
  end

  defp read_string_at(bin, pos) do
    with {:ok, len} <- u32(bin, pos),
         :ok <- vector_len(len),
         :ok <- fits(bin, pos + 4, len) do
      raw = binary_part(bin, pos + 4, len)
      if String.valid?(raw), do: {:ok, raw}, else: {:error, :corrupt}
    end
  end

  defp read_tables(_parent, _base, 0), do: {:ok, []}

  defp read_tables(parent, base, len) do
    0..(len - 1)//1
    |> Enum.reduce_while({:ok, []}, fn index, {:ok, acc} ->
      read_one_table(parent, base + index * 4, acc)
    end)
    |> reverse_ok()
  end

  defp read_one_table(parent, at, acc) do
    with {:ok, pos} <- follow(parent.bin, at),
         {:ok, child} <- open_table(parent.bin, pos, parent.depth + 1) do
      {:cont, {:ok, [child | acc]}}
    else
      {:error, _} = error -> {:halt, error}
    end
  end

  defp reverse_ok({:ok, acc}), do: {:ok, Enum.reverse(acc)}
  defp reverse_ok({:error, _} = error), do: error

  defp read_uints(body, len, width) do
    Enum.map(0..(len - 1)//1, fn index ->
      at = index * width
      <<value::little-size(^width * 8)>> = binary_part(body, at, width)
      value
    end)
  end

  defp vector_body(table, index, width) do
    case vector_start(table, index) do
      :absent ->
        :absent

      {:ok, start, len} ->
        bytes = len * width

        with :ok <- fits(table.bin, start + 4, bytes) do
          {:ok, binary_part(table.bin, start + 4, bytes), len}
        end

      {:error, _} = error ->
        error
    end
  end

  defp vector_start(table, index) do
    case follow_slot(table, index) do
      :absent ->
        :absent

      {:ok, start} ->
        with {:ok, len} <- u32(table.bin, start),
             :ok <- vector_len(len),
             :ok <- fits(table.bin, start, 4) do
          {:ok, start, len}
        end

      {:error, _} = error ->
        error
    end
  end

  defp follow_slot(table, index) do
    case slot(table, index) do
      :absent ->
        :absent

      {:ok, offset} ->
        with :ok <- inside_object(table, offset, 4),
             :ok <- fits(table.bin, table.pos + offset, 4) do
          follow(table.bin, table.pos + offset)
        end
    end
  end

  defp follow(bin, at) do
    with {:ok, relative} <- u32(bin, at),
         :ok <- nonzero(relative) do
      target = at + relative
      if target < byte_size(bin), do: {:ok, target}, else: {:error, :corrupt}
    end
  end

  defp open_table(_bin, _pos, depth) when depth > @max_depth, do: {:error, :depth}

  defp open_table(bin, pos, depth) do
    with :ok <- count_visit(),
         {:ok, soffset} <- i32(bin, pos),
         {:ok, vtable} <- vtable_pos(pos, soffset),
         :ok <- fits(bin, vtable, 4),
         {:ok, vtable_size} <- u16(bin, vtable),
         {:ok, object_size} <- u16(bin, vtable + 2),
         :ok <- vtable_ok(bin, vtable, vtable_size, object_size) do
      {:ok,
       %__MODULE__{
         bin: bin,
         pos: pos,
         vtable: vtable,
         vtable_size: vtable_size,
         object_size: object_size,
         depth: depth,
         visits: Process.get(:f3_flat_buffer_visits, 0)
       }}
    end
  end

  defp count_visit do
    visits = Process.get(:f3_flat_buffer_visits, 0) + 1
    Process.put(:f3_flat_buffer_visits, visits)
    if visits > @max_visits, do: {:error, :depth}, else: :ok
  end

  defp slot(table, index) do
    at = 4 + index * 2

    if at + 2 > table.vtable_size do
      :absent
    else
      case u16(table.bin, table.vtable + at) do
        {:ok, 0} -> :absent
        {:ok, offset} -> {:ok, offset}
        {:error, _} = error -> error
      end
    end
  end

  # The soffset is signed. A shared vtable can sit after the table, which
  # makes the stored soffset negative. Zero would point at the table itself.
  defp vtable_pos(_pos, 0), do: {:error, :corrupt}

  defp vtable_pos(pos, soffset) do
    vtable = pos - soffset
    if vtable >= 0, do: {:ok, vtable}, else: {:error, :corrupt}
  end

  defp vtable_ok(bin, vtable, size, object_size) do
    cond do
      size < 4 or rem(size, 2) != 0 or object_size < 4 ->
        {:error, :corrupt}

      not in_buffer?(bin, vtable, size) ->
        {:error, :corrupt}

      true ->
        :ok
    end
  end

  defp inside_object(table, offset, width) do
    if offset >= 4 and offset + width <= table.object_size do
      :ok
    else
      {:error, :corrupt}
    end
  end

  defp vector_len(len) when len <= @max_vector, do: :ok
  defp vector_len(_len), do: {:error, :corrupt}

  defp nonzero(0), do: {:error, :corrupt}
  defp nonzero(n) when is_integer(n) and n > 0, do: :ok

  defp fits(bin, pos, width) do
    if in_buffer?(bin, pos, width), do: :ok, else: {:error, :corrupt}
  end

  defp in_buffer?(bin, pos, width) when pos >= 0 and width >= 0 do
    pos <= byte_size(bin) and width <= byte_size(bin) - pos
  end

  defp in_buffer?(_bin, _pos, _width), do: false

  defp scalar_width(:bool), do: 1
  defp scalar_width(:u8), do: 1
  defp scalar_width(:u16), do: 2
  defp scalar_width(:i16), do: 2
  defp scalar_width(:u32), do: 4
  defp scalar_width(:i32), do: 4
  defp scalar_width(:u64), do: 8

  defp read_scalar(bin, pos, :bool) do
    <<byte>> = binary_part(bin, pos, 1)
    {:ok, byte != 0}
  end

  defp read_scalar(bin, pos, :u8) do
    <<value>> = binary_part(bin, pos, 1)
    {:ok, value}
  end

  defp read_scalar(bin, pos, :u16) do
    <<value::little-16>> = binary_part(bin, pos, 2)
    {:ok, value}
  end

  defp read_scalar(bin, pos, :i16) do
    <<value::little-signed-16>> = binary_part(bin, pos, 2)
    {:ok, value}
  end

  defp read_scalar(bin, pos, :u32) do
    <<value::little-32>> = binary_part(bin, pos, 4)
    {:ok, value}
  end

  defp read_scalar(bin, pos, :i32) do
    <<value::little-signed-32>> = binary_part(bin, pos, 4)
    {:ok, value}
  end

  defp read_scalar(bin, pos, :u64) do
    <<value::little-64>> = binary_part(bin, pos, 8)
    {:ok, value}
  end

  defp u16(bin, pos) do
    with :ok <- fits(bin, pos, 2) do
      <<value::little-16>> = binary_part(bin, pos, 2)
      {:ok, value}
    end
  end

  defp u32(bin, pos) do
    with :ok <- fits(bin, pos, 4) do
      <<value::little-32>> = binary_part(bin, pos, 4)
      {:ok, value}
    end
  end

  defp i32(bin, pos) do
    with :ok <- fits(bin, pos, 4) do
      <<value::little-signed-32>> = binary_part(bin, pos, 4)
      {:ok, value}
    end
  end
end
