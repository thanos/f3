defmodule F3 do
  @moduledoc """
  Experimental Elixir API for the F3 columnar file format.

  Upstream F3 is a research prototype. `open/2` and `close/1` acquire and
  release a byte source. `schema/1`, `metadata/1`, and `inspect/2` decode the
  postscript and the FlatBuffers footer. `read/2` returns columnar batches.
  `stream/2` returns a lazy stream and does not pread until the first pull.
  Writing is not implemented. Wasm bytes are not executed.

  `max_metadata_bytes` on the metadata calls caps the postscript size fields.
  The default is `F3.Postscript.max_metadata_bytes/0`.

  A memory source is `open(path, source: {:memory, binary})` or
  `open({:memory, binary})`. When the `:source` option is a memory binary,
  `path` is not opened.
  """

  import Kernel, except: [inspect: 1]

  alias F3.IO.Local
  alias F3.IO.Memory

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
  Returns the logical schema from the footer.

  `max_metadata_bytes` overrides the allocation cap for this call.
  """
  @spec schema(F3.File.t(), keyword()) :: {:ok, F3.Schema.t()} | {:error, F3.Error.t()}
  def schema(file, opts \\ [])

  def schema(file, opts) when is_list(opts) do
    with {:ok, metadata} <- load_metadata(file, opts, :schema, [:max_metadata_bytes]) do
      {:ok, metadata.schema}
    end
  end

  def schema(_file, _opts) do
    {:error, F3.Error.invalid_argument(:schema, "options must be a keyword list")}
  end

  @doc """
  Returns footer and column metadata.

  Checksums are reported and not verified. Wasm sections are offsets only.
  `max_metadata_bytes` overrides the allocation cap for this call.
  """
  @spec metadata(F3.File.t(), keyword()) :: {:ok, F3.Metadata.t()} | {:error, F3.Error.t()}
  def metadata(file, opts \\ [])

  def metadata(file, opts) when is_list(opts) do
    load_metadata(file, opts, :metadata, [:max_metadata_bytes])
  end

  def metadata(_file, _opts) do
    {:error, F3.Error.invalid_argument(:metadata, "options must be a keyword list")}
  end

  @doc """
  Reads row data into columnar batches.

  Options:

    * `:columns` — logical field names. Omitted means every top-level field.
      An unknown name is `:invalid_projection`.
    * `:row_groups` — zero-based indexes. An index past the footer is
      `:invalid_argument`. Omitted means every row group.
    * `:batch_size` — a positive integer. The default is 8192.

  One native call decodes a whole encoding unit. Elixir slices it to
  `batch_size`. These fixtures are smaller than one unit. Without the native
  decoder this returns `:native_unavailable` and does not read the payload.
  """
  @spec read(F3.File.t(), keyword()) :: {:ok, [F3.Batch.t()]} | {:error, F3.Error.t()}
  def read(file, opts \\ []), do: F3.Reader.read(file, opts)

  @doc """
  Lazy columnar batches.

  The stream does not pread until the first pull. `Enum.take/2` stops further
  reads. The caller still owns `close/1`. Options match `read/2`. A pull that
  cannot decode throws `{:f3, %F3.Error{}}`.
  """
  @spec stream(F3.File.t(), keyword()) :: {:ok, Enumerable.t()} | {:error, F3.Error.t()}
  def stream(file, opts \\ []), do: F3.Reader.stream(file, opts)

  @doc """
  Textual inspection of a file.

  This name is the public inspection API. It is unrelated to `Kernel.inspect/2`.
  The default is a compact summary. `detail: true` adds row groups, encoding
  units, and optional sections. `format: :json` returns the golden metadata
  map encoded as JSON. Neither form includes column payloads.

  `max_metadata_bytes` overrides the allocation cap for this call.
  """
  @spec inspect(F3.File.t(), keyword()) :: {:ok, String.t()} | {:error, F3.Error.t()}
  def inspect(file, opts \\ [])

  def inspect(file, opts) when is_list(opts) do
    allowed = [:max_metadata_bytes, :detail, :format]

    with {:ok, metadata} <- load_metadata(file, opts, :inspect, allowed),
         {:ok, detail} <- boolean_option(opts, :detail, false, :inspect),
         {:ok, format} <- output_format(opts) do
      {:ok, F3.Inspection.render(metadata, format, detail)}
    end
  end

  def inspect(_file, _opts) do
    {:error, F3.Error.invalid_argument(:inspect, "options must be a keyword list")}
  end

  defp load_metadata(file, opts, operation, allowed) do
    with {:ok, file} <- ensure_open(file, operation),
         :ok <- reject_unknown_opts(opts, allowed, operation),
         {:ok, max} <- metadata_cap(opts, operation) do
      F3.Footer.load(file, max)
    end
  end

  defp metadata_cap(opts, operation) do
    case Keyword.get(opts, :max_metadata_bytes, F3.Postscript.max_metadata_bytes()) do
      max when is_integer(max) and max >= 0 ->
        {:ok, max}

      _other ->
        {:error,
         F3.Error.invalid_argument(operation, "max_metadata_bytes must be a non-negative integer")}
    end
  end

  defp boolean_option(opts, key, default, operation) do
    case Keyword.get(opts, key, default) do
      value when is_boolean(value) ->
        {:ok, value}

      _other ->
        {:error, F3.Error.invalid_argument(operation, "#{key} must be a boolean")}
    end
  end

  defp output_format(opts) do
    case Keyword.get(opts, :format, :text) do
      :text -> {:ok, :text}
      :json -> {:ok, :json}
      _other -> {:error, F3.Error.invalid_argument(:inspect, "format must be :text or :json")}
    end
  end

  defp ensure_open(%F3.File{closed: true}, operation), do: {:error, F3.Error.closed(operation)}
  defp ensure_open(%F3.File{} = file, _operation), do: {:ok, file}

  defp ensure_open(_other, operation) do
    {:error, F3.Error.invalid_argument(operation, "expected an F3.File")}
  end

  defp open_local(path) do
    case Local.open(path) do
      {:ok, state} ->
        {:ok, %F3.File{source_module: Local, source_state: state, origin: path}}

      {:error, %F3.Error{}} = error ->
        error
    end
  end

  defp open_memory(binary) do
    case Memory.open(binary) do
      {:ok, state} ->
        {:ok, %F3.File{source_module: Memory, source_state: state, origin: :memory}}

      {:error, %F3.Error{}} = error ->
        error
    end
  end

  defp reject_unknown_opts(opts, allowed, operation \\ :open) do
    unknown = opts |> Keyword.keys() |> Enum.reject(&(&1 in allowed))

    case unknown do
      [] ->
        :ok

      keys ->
        {:error, F3.Error.invalid_argument(operation, "unknown options: #{Kernel.inspect(keys)}")}
    end
  end

  defp format_option(value) when is_atom(value), do: Atom.to_string(value)
  defp format_option(value) when is_binary(value), do: "a binary of #{byte_size(value)} bytes"
  defp format_option(value) when is_tuple(value), do: "a tuple of size #{tuple_size(value)}"
  defp format_option(_value), do: "an unsupported value"
end
