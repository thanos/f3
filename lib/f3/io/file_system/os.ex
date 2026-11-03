defmodule F3.IO.FileSystem.OS do
  @moduledoc """
  `F3.IO.FileSystem` implementation that calls `File` and `:file`.
  """

  @behaviour F3.IO.FileSystem

  @impl true
  def stat(path), do: File.stat(path)

  @impl true
  def open(path, modes), do: :file.open(path, modes)

  @impl true
  def pread(fd, offset, length), do: :file.pread(fd, offset, length)

  @impl true
  def close(fd), do: :file.close(fd)
end
