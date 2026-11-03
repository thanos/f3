defmodule F3.IO.Memory do
  @moduledoc """
  In-memory byte source.

  The struct keeps the caller's binary until `close/1`, which drops this
  source's reference. `Inspect` does not print the bytes.
  """

  @behaviour F3.IO.Source

  @enforce_keys [:data, :size]
  defstruct [:data, :size, closed: false]

  @type t :: %__MODULE__{data: binary(), size: non_neg_integer(), closed: boolean()}

  @doc """
  Wraps `data`. The binary may be empty.
  """
  @spec open(binary()) :: {:ok, t()} | {:error, F3.Error.t()}
  def open(data) when is_binary(data) do
    {:ok, %__MODULE__{data: data, size: byte_size(data)}}
  end

  def open(_data) do
    {:error, F3.Error.invalid_argument(:open, "memory source must be a binary")}
  end

  @impl true
  def size(%__MODULE__{closed: true}), do: {:error, F3.Error.closed(:size)}
  def size(%__MODULE__{size: size}), do: {:ok, size}

  @impl true
  def pread(%__MODULE__{closed: true}, _offset, _length), do: {:error, F3.Error.closed(:pread)}

  def pread(%__MODULE__{}, offset, length)
      when not is_integer(offset) or not is_integer(length) or offset < 0 or length < 0 do
    {:error, F3.Error.invalid_argument(:pread, "offset and length must be non-negative integers")}
  end

  def pread(%__MODULE__{data: data, size: size}, offset, length) do
    {:ok, slice(data, size, offset, length)}
  end

  @impl true
  def close(%__MODULE__{closed: true} = state), do: {:ok, state}

  def close(%__MODULE__{} = state) do
    {:ok, %{state | data: <<>>, closed: true}}
  end

  @doc false
  @spec slice(binary(), non_neg_integer(), non_neg_integer(), non_neg_integer()) :: binary()
  def slice(_data, size, offset, length) when length == 0 or offset >= size, do: <<>>

  def slice(data, size, offset, length) do
    to_read = min(length, size - offset)
    binary_part(data, offset, to_read)
  end

  defimpl Inspect do
    def inspect(%F3.IO.Memory{size: size, closed: closed}, _opts) do
      "#F3.IO.Memory<size: #{size}, closed: #{closed}>"
    end
  end
end
