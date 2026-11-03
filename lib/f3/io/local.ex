defmodule F3.IO.Local do
  @moduledoc """
  Local filesystem source.

  `open/1` stats the path and keeps that size for later reads. `pread/3`
  never asks the operating system for more bytes than remain in that size.
  A missing path is `:not_found`. `close/1` is idempotent.
  """

  @behaviour F3.IO.Source

  @enforce_keys [:path, :size]
  defstruct [:path, :fd, :size, closed: false]

  @type t :: %__MODULE__{
          path: Path.t(),
          fd: :file.fd() | nil,
          size: non_neg_integer(),
          closed: boolean()
        }

  @doc """
  Opens `path` for positioned reads.
  """
  @spec open(Path.t()) :: {:ok, t()} | {:error, F3.Error.t()}
  def open(path) when is_binary(path) do
    with {:ok, stat} <- stat(path),
         :ok <- ensure_regular(stat, path),
         {:ok, fd} <- open_fd(path) do
      {:ok, %__MODULE__{path: path, fd: fd, size: stat.size}}
    end
  end

  def open(_path) do
    {:error, F3.Error.invalid_argument(:open, "path must be a binary")}
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

  def pread(%__MODULE__{size: size}, offset, length) when length == 0 or offset >= size do
    {:ok, <<>>}
  end

  def pread(%__MODULE__{fd: fd, size: size, path: path}, offset, length) do
    to_read = min(length, size - offset)

    case :file.pread(fd, offset, to_read) do
      {:ok, data} when is_binary(data) -> {:ok, data}
      :eof -> {:ok, <<>>}
      {:error, reason} -> {:error, F3.Error.io(:pread, reason, %{path: path})}
    end
  end

  @impl true
  def close(%__MODULE__{closed: true} = state), do: {:ok, state}

  def close(%__MODULE__{fd: fd, path: path} = state) do
    case :file.close(fd) do
      :ok -> {:ok, %{state | fd: nil, closed: true}}
      {:error, reason} -> {:error, F3.Error.io(:close, reason, %{path: path})}
    end
  end

  defp stat(path) do
    case File.stat(path) do
      {:ok, stat} -> {:ok, stat}
      {:error, :enoent} -> {:error, F3.Error.not_found(path)}
      {:error, reason} -> {:error, F3.Error.io(:stat, reason, %{path: path})}
    end
  end

  defp ensure_regular(%File.Stat{type: :regular}, _path), do: :ok

  defp ensure_regular(%File.Stat{type: type}, path) do
    {:error, F3.Error.invalid_argument(:open, "not a regular file (#{type}): #{path}")}
  end

  defp open_fd(path) do
    case :file.open(path, [:read, :binary, :raw]) do
      {:ok, fd} -> {:ok, fd}
      {:error, :enoent} -> {:error, F3.Error.not_found(path)}
      {:error, reason} -> {:error, F3.Error.io(:open, reason, %{path: path})}
    end
  end

  defimpl Inspect do
    def inspect(%F3.IO.Local{path: path, size: size, closed: closed}, _opts) do
      "#F3.IO.Local<path: #{inspect(path)}, size: #{size}, closed: #{closed}>"
    end
  end
end
