defmodule F3 do
  @moduledoc """
  Experimental Elixir API for the F3 columnar file format.

  Upstream F3 is a research prototype. This package does not read or write
  row data yet. `open/2` and `close/1` acquire and release a byte source.
  `schema/1`, `metadata/1`, `read/2`, `stream/2`, and `inspect/2` check the
  handle and then return `:not_implemented`.

  `stream/2` returns that error immediately. It does not read the file and
  it does not build a `Stream`.

  A memory source is `open(path, source: {:memory, binary})` or
  `open({:memory, binary})`. When the `:source` option is a memory binary,
  `path` is not opened.
  """

  import Kernel, except: [inspect: 1]

  @doc """
  Opens a local path or an in-memory binary.

  The returned handle is not validated as F3. Missing local paths return
  `{:error, %F3.Error{category: :not_found}}`.
  """
  @spec open(Path.t() | {:memory, binary()}, keyword()) ::
          {:ok, F3.File.t()} | {:error, F3.Error.t()}
  def open(source, opts \\ [])

  def open(path, opts) when is_binary(path) and is_list(opts) do
    with :ok <- reject_unknown_opts(opts, [:source]) do
      case Keyword.get(opts, :source, :file) do
        :file ->
          open_local(path)

        {:memory, binary} when is_binary(binary) ->
          open_memory(binary)

        {:memory, _other} ->
          {:error, F3.Error.invalid_argument(:open, "memory source must be a binary")}

        other ->
          {:error, F3.Error.invalid_argument(:open, "unknown source #{format_option(other)}")}
      end
    end
  end

  def open({:memory, binary}, opts) when is_binary(binary) and is_list(opts) do
    with :ok <- reject_unknown_opts(opts, []) do
      open_memory(binary)
    end
  end

  def open(_source, opts) when is_list(opts) do
    {:error, F3.Error.invalid_argument(:open, "expected a path or {:memory, binary}")}
  end

  def open(_source, _opts) do
    {:error, F3.Error.invalid_argument(:open, "options must be a keyword list")}
  end

  @doc """
  Releases the source. Closing a closed handle returns `{:ok, file}`.
  """
  @spec close(F3.File.t()) :: {:ok, F3.File.t()} | {:error, F3.Error.t()}
  def close(%F3.File{closed: true} = file), do: {:ok, file}

  def close(%F3.File{source_module: module, source_state: state} = file) do
    case module.close(state) do
      {:ok, new_state} -> {:ok, %{file | source_state: new_state, closed: true}}
      {:error, %F3.Error{}} = error -> error
    end
  end

  def close(_other) do
    {:error, F3.Error.invalid_argument(:close, "expected an F3.File")}
  end

  @doc """
  Returns the logical schema. Not implemented.
  """
  @spec schema(F3.File.t()) :: {:error, F3.Error.t()}
  def schema(file), do: unimplemented(file, :schema)

  @doc """
  Returns file metadata. Not implemented.
  """
  @spec metadata(F3.File.t()) :: {:error, F3.Error.t()}
  def metadata(file), do: unimplemented(file, :metadata)

  @doc """
  Reads row data. Not implemented. Options are not interpreted.
  """
  @spec read(F3.File.t(), keyword()) :: {:error, F3.Error.t()}
  def read(file, opts \\ [])

  def read(file, opts) when is_list(opts), do: unimplemented(file, :read)

  def read(_file, _opts) do
    {:error, F3.Error.invalid_argument(:read, "options must be a keyword list")}
  end

  @doc """
  Streaming read. Not implemented.

  The function returns as soon as the handle is checked. It does not read
  bytes and it does not return a stream.
  """
  @spec stream(F3.File.t(), keyword()) :: {:error, F3.Error.t()}
  def stream(file, opts \\ [])

  def stream(file, opts) when is_list(opts), do: unimplemented(file, :stream)

  def stream(_file, _opts) do
    {:error, F3.Error.invalid_argument(:stream, "options must be a keyword list")}
  end

  @doc """
  Textual inspection of a file. Not implemented.

  This name is the public inspection API. It is unrelated to `Kernel.inspect/2`.
  """
  @spec inspect(F3.File.t(), keyword()) :: {:error, F3.Error.t()}
  def inspect(file, opts \\ [])

  def inspect(file, opts) when is_list(opts), do: unimplemented(file, :inspect)

  def inspect(_file, _opts) do
    {:error, F3.Error.invalid_argument(:inspect, "options must be a keyword list")}
  end

  defp unimplemented(file, operation) do
    with {:ok, _file} <- ensure_open(file, operation) do
      {:error, F3.Error.not_implemented(operation)}
    end
  end

  defp ensure_open(%F3.File{closed: true}, operation), do: {:error, F3.Error.closed(operation)}
  defp ensure_open(%F3.File{} = file, _operation), do: {:ok, file}

  defp ensure_open(_other, operation) do
    {:error, F3.Error.invalid_argument(operation, "expected an F3.File")}
  end

  defp open_local(path) do
    case F3.IO.Local.open(path) do
      {:ok, state} ->
        {:ok, %F3.File{source_module: F3.IO.Local, source_state: state, origin: path}}

      {:error, %F3.Error{}} = error ->
        error
    end
  end

  defp open_memory(binary) do
    case F3.IO.Memory.open(binary) do
      {:ok, state} ->
        {:ok, %F3.File{source_module: F3.IO.Memory, source_state: state, origin: :memory}}

      {:error, %F3.Error{}} = error ->
        error
    end
  end

  defp reject_unknown_opts(opts, allowed) do
    unknown = opts |> Keyword.keys() |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] ->
        :ok

      keys ->
        {:error, F3.Error.invalid_argument(:open, "unknown options: #{Kernel.inspect(keys)}")}
    end
  end

  defp format_option(value) when is_atom(value), do: Atom.to_string(value)
  defp format_option(value) when is_binary(value), do: "a binary of #{byte_size(value)} bytes"
  defp format_option(value) when is_tuple(value), do: "a tuple of size #{tuple_size(value)}"
  defp format_option(_value), do: "an unsupported value"
end
