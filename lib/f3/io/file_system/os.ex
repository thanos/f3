defmodule F3.IO.FileSystem.OS do
  @moduledoc """
  `F3.IO.FileSystem` implementation that calls `File` and `:file`.

  `stat/1` uses `File.stat/1`. `open/2`, `pread/3`, and `close/1` use the
  Erlang `:file` module. Errors are the atoms those functions return.
  They do not raise for a missing path.
  """

  @behaviour F3.IO.FileSystem

  @doc """
  `File.stat/1` for `path`.

  ## Examples

      iex> {:ok, stat} = F3.IO.FileSystem.OS.stat("test/fixtures/small.f3")
      iex> stat.size
      4168

      iex> F3.IO.FileSystem.OS.stat("missing-file.f3")
      {:error, :enoent}
  """
  @impl true
  def stat(path), do: File.stat(path)

  @doc """
  `:file.open/2` for `path` and `modes`.

  ## Examples

      iex> {:ok, fd} = F3.IO.FileSystem.OS.open("test/fixtures/small.f3", [:read, :binary])
      iex> :ok = F3.IO.FileSystem.OS.close(fd)
      iex> is_pid(fd) or is_reference(fd) or is_tuple(fd) or is_atom(fd)
      true
  """
  @impl true
  def open(path, modes), do: :file.open(path, modes)

  @doc """
  `:file.pread/3` for an open descriptor.

  ## Examples

      iex> {:ok, fd} = F3.IO.FileSystem.OS.open("test/fixtures/small.f3", [:read, :binary])
      iex> {:ok, "F3"} = F3.IO.FileSystem.OS.pread(fd, 4166, 2)
      iex> :ok = F3.IO.FileSystem.OS.close(fd)
      :ok
  """
  @impl true
  def pread(fd, offset, length), do: :file.pread(fd, offset, length)

  @doc """
  `:file.close/1` for an open descriptor.

  ## Examples

      iex> {:ok, fd} = F3.IO.FileSystem.OS.open("test/fixtures/small.f3", [:read, :binary])
      iex> F3.IO.FileSystem.OS.close(fd)
      :ok
  """
  @impl true
  def close(fd), do: :file.close(fd)
end
