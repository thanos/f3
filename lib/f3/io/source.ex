defmodule F3.IO.Source do
  @moduledoc """
  Positioned byte source.

  `pread/3` reads at most `length` bytes. That argument is the caller's cap.
  There is no process-wide size limit. A read that starts at or past the end
  returns `{:ok, ""}`. A read that extends past the end returns the bytes
  that remain.   Implementations return a tagged error instead of raising.

  `F3.IO.Memory` is the small implementation. A custom source has the same
  three callbacks:

      defmodule ByteSource do
        @behaviour F3.IO.Source

        defstruct [:data, closed: false]

        @impl true
        def size(%{closed: true}), do: {:error, F3.Error.closed(:size)}
        def size(%{data: data}), do: {:ok, byte_size(data)}

        @impl true
        def pread(%{closed: true}, _offset, _length), do: {:error, F3.Error.closed(:pread)}

        def pread(%{data: data}, offset, length) do
          {:ok, F3.IO.Memory.slice(data, byte_size(data), offset, length)}
        end

        @impl true
        def close(state), do: {:ok, %{state | data: <<>>, closed: true}}
      end
  """

  @typedoc "Opaque handle owned by one source implementation."
  @type state :: term()

  @doc """
  Byte length of the source.

  A closed handle returns `{:error, %F3.Error{category: :closed}}`.
  """
  @callback size(state()) :: {:ok, non_neg_integer()} | {:error, F3.Error.t()}

  @doc """
  Reads at most `length` bytes starting at `offset`.

  A start at or past the end returns `{:ok, ""}`. A read past the end
  returns the bytes that remain. `offset` and `length` are non-negative
  integers. A closed handle is `:closed`.
  """
  @callback pread(state(), non_neg_integer(), non_neg_integer()) ::
              {:ok, binary()} | {:error, F3.Error.t()}

  @doc """
  Releases the source. Closing a closed handle returns `{:ok, state}`.
  """
  @callback close(state()) :: {:ok, state()} | {:error, F3.Error.t()}
end
