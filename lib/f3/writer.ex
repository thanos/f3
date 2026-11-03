defmodule F3.Writer do
  @moduledoc """
  File writer.

  Writing is Stage 4. Every function returns
  `{:error, %F3.Error{category: :not_implemented}}`. There is no writer
  struct and no partial file is created.
  """

  @doc """
  Opens a writer. Not implemented.
  """
  @spec open(Path.t(), keyword()) :: {:error, F3.Error.t()}
  def open(path, opts \\ [])

  def open(_path, _opts) do
    {:error, F3.Error.not_implemented(:writer_open)}
  end

  @doc """
  Writes one batch. Not implemented.
  """
  @spec write(term(), term()) :: {:error, F3.Error.t()}
  def write(_writer, _batch) do
    {:error, F3.Error.not_implemented(:writer_write)}
  end

  @doc """
  Closes a writer. Not implemented.
  """
  @spec close(term()) :: {:error, F3.Error.t()}
  def close(_writer) do
    {:error, F3.Error.not_implemented(:writer_close)}
  end
end
