defmodule F3.IO.FileSystem do
  @moduledoc """
  Operating-system calls used by `F3.IO.Local`.

  Production code uses `F3.IO.FileSystem.OS`. Tests pass a Mox double as
  `:file_system` on `F3.IO.Local.open/2` so read and close failures can be
  returned without changing a real file.

  A double returns the same tagged tuples as `File` and `:file`:

      defmodule StubFiles do
        @behaviour F3.IO.FileSystem

        @impl true
        def stat(_path), do: {:ok, %File.Stat{type: :regular, size: 2}}

        @impl true
        def open(_path, _modes), do: {:ok, :fd}

        @impl true
        def pread(_fd, _offset, length), do: {:ok, String.duplicate("a", length)}

        @impl true
        def close(_fd), do: :ok
      end
  """

  @doc """
  File metadata for `path`. A missing path is `{:error, :enoent}`.
  """
  @callback stat(Path.t()) :: {:ok, File.Stat.t()} | {:error, atom()}

  @doc """
  Opens `path` with `modes`. The modes used by `F3.IO.Local` are
  `[:read, :raw, :binary]`.
  """
  @callback open(Path.t(), [atom()]) :: {:ok, term()} | {:error, atom()}

  @doc """
  Reads `length` bytes at `offset` from an open descriptor.
  `:eof` means the position is past the file.
  """
  @callback pread(term(), non_neg_integer(), non_neg_integer()) ::
              {:ok, binary()} | :eof | {:error, atom()}

  @doc """
  Closes a descriptor. `:ok` is success. `{:error, reason}` is an OS error.
  """
  @callback close(term()) :: :ok | {:error, atom()}
end
