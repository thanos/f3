defmodule F3.Wasm do
  @moduledoc """
  Loads one embedded Wasm module after the caller has opted in.

  Metadata inspection does not call this module. `lib_urls` are not read.
  The section named `WASMBinaries` is a FlatBuffers table of offsets. The
  module bytes are read only for the `wasm_id` on the encoding unit, and
  only when `F3.Dispatch` has already chosen `:wasm`.

  The host fuel budget is #{5_000_000} instructions. Upstream does not set
  fuel. Linear memory is capped at 8 MiB. A module is at most 1 MiB unless
  `wasm_module_bytes:` raises that, and never above 16 MiB. An omitted
  `wasm_id` selects module 0.
  """

  alias F3.Error
  alias F3.FlatBuffer, as: FB

  @fuel 5_000_000
  @memory_bytes 8 * 1024 * 1024
  @default_module_bytes 1024 * 1024
  # The pinned fff-ude-example-fff artifact is 10_661_135 bytes, above 8 MiB.
  @max_module_bytes 16 * 1024 * 1024
  @section "WASMBinaries"

  @doc """
  Instruction budget passed to Wasmtime. Upstream sets no fuel.

  ## Examples

      iex> F3.Wasm.fuel()
      5_000_000
  """
  @spec fuel() :: pos_integer()
  def fuel, do: @fuel

  @doc """
  Linear memory cap, in bytes.

  ## Examples

      iex> F3.Wasm.memory_bytes()
      8_388_608
  """
  @spec memory_bytes() :: pos_integer()
  def memory_bytes, do: @memory_bytes

  @doc """
  Default maximum module size, in bytes.

  ## Examples

      iex> F3.Wasm.default_module_bytes()
      1_048_576
  """
  @spec default_module_bytes() :: pos_integer()
  def default_module_bytes, do: @default_module_bytes

  @doc """
  Hard maximum for `wasm_module_bytes:`. The pinned built-in module is
  larger than 8 MiB, so the ceiling is 16 MiB.

  ## Examples

      iex> F3.Wasm.max_module_bytes()
      16_777_216
  """
  @spec max_module_bytes() :: pos_integer()
  def max_module_bytes, do: @max_module_bytes

  @doc """
  Decodes one unit with the sandboxed host. The module bytes do not leave
  the NIF as an Arrow buffer. The return is an owned `F3.Column`.

  `plan` must include `:operation`. A nested `type` is
  `:unsupported_encoding` and does not load a module. A missing Wasm section
  is `:corrupt`. This raises `KeyError` when `plan.operation` is absent.

  ## Examples

      iex> plan = %{operation: :read}
      iex> {:error, error} = F3.Wasm.decode(plan, %{}, <<>>, :list)
      iex> error.category
      :unsupported_encoding
  """
  @spec decode(map(), map(), binary(), atom()) :: {:ok, F3.Column.t()} | {:error, Error.t()}
  def decode(plan, unit, bytes, type) do
    operation = plan.operation

    with :ok <- concrete(type, operation),
         {:ok, module} <- load_module(plan, unit.wasm_id, operation) do
      F3.Native.apply_wasm(module, bytes, unit.compression, type, unit.num_rows, operation)
    end
  end

  @doc """
  Parses a `WASMBinaries` FlatBuffers root. Field `lib_urls` is not walked.
  A buffer that is not a table is `:corrupt`. A non-binary raises no error
  here. It returns the same `:corrupt` error.

  ## Examples

      iex> {:error, error} = F3.Wasm.modules(<<>>)
      iex> error.message
      "wasm section is truncated"
  """
  @spec modules(binary()) :: {:ok, [map()]} | {:error, Error.t()}
  def modules(bin) when is_binary(bin) do
    with {:ok, root} <- FB.root(bin),
         {:ok, tables} <- FB.tables(root, 0) do
      map_modules(tables)
    else
      {:error, _reason} -> {:error, Error.corrupt(:read, "wasm section is truncated")}
    end
  end

  def modules(_bin), do: {:error, Error.corrupt(:read, "wasm section is truncated")}

  defp map_modules(tables) do
    Enum.reduce_while(tables, {:ok, []}, fn table, {:ok, acc} ->
      case one_module(table) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        {:error, %Error{}} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      error -> error
    end
  end

  defp one_module(table) do
    with {:ok, offset} <- FB.scalar(table, 0, :u64, 0),
         {:ok, size} <- FB.scalar(table, 1, :u32, 0),
         {:ok, compression} <- FB.scalar(table, 2, :u8, 0) do
      {:ok, %{offset: offset, size: size, compression: compression_atom(compression)}}
    else
      {:error, _reason} -> {:error, Error.corrupt(:read, "wasm section is truncated")}
    end
  end

  defp load_module(plan, wasm_id, operation) do
    with {:ok, section} <- find_section(plan, operation),
         {:ok, bytes} <- read_capped(plan.file, section, operation),
         {:ok, modules} <- modules(bytes),
         {:ok, entry} <- pick(modules, wasm_id, operation),
         :ok <- module_cap(entry.size, plan.module_cap, operation) do
      read_capped(plan.file, entry, operation)
    end
  end

  defp find_section(plan, operation) do
    case Enum.find(plan.sections, &(&1.name == @section)) do
      nil -> {:error, Error.corrupt(operation, "wasm section is missing")}
      section -> {:ok, section}
    end
  end

  defp pick(modules, nil, operation), do: pick(modules, 0, operation)

  defp pick(modules, wasm_id, operation) when is_integer(wasm_id) and wasm_id >= 0 do
    case Enum.at(modules, wasm_id, :missing) do
      :missing -> {:error, Error.corrupt(operation, "wasm_id is past the section")}
      entry -> {:ok, entry}
    end
  end

  defp pick(_modules, _wasm_id, operation) do
    {:error, Error.corrupt(operation, "wasm_id is past the section")}
  end

  defp module_cap(size, cap, operation) do
    cond do
      size > @max_module_bytes ->
        {:error, Error.resource_limit(operation, "wasm module is above 16 MiB", %{size: size})}

      size > cap ->
        {:error,
         Error.resource_limit(operation, "wasm module is above the byte cap", %{size: size})}

      true ->
        :ok
    end
  end

  defp read_capped(file, %{offset: offset, size: size, compression: compression}, operation) do
    if compression != :uncompressed do
      {:error, Error.unsupported_encoding(operation, "compressed wasm section")}
    else
      case file.source_module.pread(file.source_state, offset, size) do
        {:ok, bytes} when byte_size(bytes) == size -> {:ok, bytes}
        {:ok, _short} -> {:error, Error.truncated(operation, "wasm section is short")}
        {:error, %Error{}} = error -> error
      end
    end
  end

  defp concrete(type, _operation)
       when type in [:i64, :i32, :u64, :u32, :u16, :u8, :f64, :f32, :bool, :utf8], do: :ok

  defp concrete(_type, operation) do
    {:error, Error.unsupported_encoding(operation, "nested wasm output is not decoded")}
  end

  defp compression_atom(0), do: :uncompressed
  defp compression_atom(1), do: :zstd
  defp compression_atom(2), do: :lz4
  defp compression_atom(other), do: {:unknown, other}
end
