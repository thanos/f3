defmodule F3.Error do
  @moduledoc """
  Error returned by the public F3 API.

  `message` is safe to show to a caller. It does not include file bytes,
  secrets, or an underlying payload. `context` carries small identifiers
  such as a path, offset, or operation name.
  """

  @enforce_keys [:reason, :category, :message]
  defstruct [:reason, :category, :message, :cause, context: %{}]

  @typedoc """
  Stable class of a failure.

  `:not_implemented` is a feature this build does not perform.
  `:not_found` is a missing path or HTTP object. `:io` is a source failure.
  `:closed` is a handle that was already released. `:invalid_argument` is a
  caller value this function does not accept. `:invalid_magic` is a file that
  does not end in `F3`. `:unsupported_version` is a wire pair other than 0.1.
  `:truncated` is a short file or a short HTTP body. `:corrupt_metadata` is a
  footer that does not describe the file. `:unsupported_encoding` is an
  encoding this build will not decode. `:invalid_projection` is an unknown
  column name. `:checksum` is a stored chunk checksum that did not match.
  `:resource_limit` is a size above the caller's cap, including a timeout.
  `:invalid_type` is a value that does not fit the field. `:native_unavailable`
  means the NIF was not compiled. `:corrupt` is an encoding unit that could
  not be decoded.
  """
  @type category ::
          :not_implemented
          | :not_found
          | :io
          | :closed
          | :invalid_argument
          | :invalid_magic
          | :unsupported_version
          | :truncated
          | :corrupt_metadata
          | :unsupported_encoding
          | :invalid_projection
          | :checksum
          | :resource_limit
          | :invalid_type
          | :native_unavailable
          | :corrupt

  @typedoc """
  One failure.

  `reason` is the operation or the underlying atom, such as `:enoent`.
  `category` is the stable class. `message` is safe to show. `cause` is
  reserved and is `nil` for errors this library builds. `context` holds
  small identifiers. Constructors set `context.operation`. File bytes and
  secrets are not fields.
  """
  @type t :: %__MODULE__{
          reason: atom(),
          category: category(),
          message: String.t(),
          cause: term(),
          context: map()
        }

  @doc """
  Builds an error for an operation this experimental version does not perform.

  ## Examples

      iex> error = F3.Error.not_implemented(:read)
      iex> {error.category, error.message}
      {:not_implemented, "read is not implemented in this experimental build"}
  """
  @spec not_implemented(atom()) :: t()
  def not_implemented(operation) when is_atom(operation) do
    %__MODULE__{
      reason: operation,
      category: :not_implemented,
      message: "#{operation} is not implemented in this experimental build",
      context: %{operation: operation}
    }
  end

  @doc """
  The handle has been closed.

  ## Examples

      iex> error = F3.Error.closed(:read)
      iex> {error.category, error.context.operation}
      {:closed, :read}
  """
  @spec closed(atom()) :: t()
  def closed(operation) when is_atom(operation) do
    %__MODULE__{
      reason: :closed,
      category: :closed,
      message: "F3 file is closed",
      context: %{operation: operation}
    }
  end

  @doc """
  The caller passed a value the function does not accept.

  `operation` is the public call. `message` is the sentence returned to the
  caller. This does not raise.

  ## Examples

      iex> error = F3.Error.invalid_argument(:open, "options must be a keyword list")
      iex> error.category
      :invalid_argument
  """
  @spec invalid_argument(atom(), String.t()) :: t()
  def invalid_argument(operation, message)
      when is_atom(operation) and is_binary(message) do
    %__MODULE__{
      reason: operation,
      category: :invalid_argument,
      message: message,
      context: %{operation: operation}
    }
  end

  @doc """
  A local path does not exist. `reason` is `:enoent`.

  ## Examples

      iex> error = F3.Error.not_found("missing-file.f3")
      iex> error.message
      "file not found: missing-file.f3"
  """
  @spec not_found(Path.t()) :: t()
  def not_found(path) when is_binary(path) do
    %__MODULE__{
      reason: :enoent,
      category: :not_found,
      message: "file not found: #{path}",
      context: %{path: path}
    }
  end

  @doc """
  A source operation failed. `reason` is an Erlang file error atom.
  `context` is merged with `%{operation: operation}`. The default context
  is an empty map.

  ## Examples

      iex> error = F3.Error.io(:pread, :eacces)
      iex> error.message
      "pread failed: eacces"

      iex> error = F3.Error.io(:pread, :redirect, %{status: 301})
      iex> error.context.status
      301
  """
  @spec io(atom(), atom(), map()) :: t()
  def io(operation, reason, context \\ %{})
      when is_atom(operation) and is_atom(reason) and is_map(context) do
    %__MODULE__{
      reason: reason,
      category: :io,
      message: "#{operation} failed: #{reason}",
      context: Map.put(context, :operation, operation)
    }
  end

  @doc """
  The file ends before a required field. `context` defaults to an empty map.

  ## Examples

      iex> error = F3.Error.truncated(:open, "file is shorter than the 32 byte postscript")
      iex> error.category
      :truncated
  """
  @spec truncated(atom(), String.t(), map()) :: t()
  def truncated(operation, message, context \\ %{})
      when is_atom(operation) and is_binary(message) and is_map(context) do
    build(:truncated, :truncated, operation, message, context)
  end

  @doc """
  The last two bytes are not the F3 magic.

  ## Examples

      iex> F3.Error.invalid_magic(:open).message
      "file does not end with the F3 magic"
  """
  @spec invalid_magic(atom()) :: t()
  def invalid_magic(operation) when is_atom(operation) do
    build(
      :invalid_magic,
      :invalid_magic,
      operation,
      "file does not end with the F3 magic",
      %{}
    )
  end

  @doc """
  The postscript version is outside the pinned pair.

  ## Examples

      iex> error = F3.Error.unsupported_version(:open, 1, 0)
      iex> error.message
      "unsupported F3 version 1.0"
  """
  @spec unsupported_version(atom(), non_neg_integer(), non_neg_integer()) :: t()
  def unsupported_version(operation, major, minor)
      when is_atom(operation) and is_integer(major) and is_integer(minor) do
    build(
      :unsupported_version,
      :unsupported_version,
      operation,
      "unsupported F3 version #{major}.#{minor}",
      %{major_version: major, minor_version: minor}
    )
  end

  @doc """
  A size, offset, or FlatBuffers field does not describe this file.

  ## Examples

      iex> F3.Error.corrupt_metadata(:open, "footer is truncated").category
      :corrupt_metadata
  """
  @spec corrupt_metadata(atom(), String.t(), map()) :: t()
  def corrupt_metadata(operation, message, context \\ %{})
      when is_atom(operation) and is_binary(message) and is_map(context) do
    build(:corrupt_metadata, :corrupt_metadata, operation, message, context)
  end

  @doc """
  The file names an encoding this build will not decode.

  ## Examples

      iex> F3.Error.unsupported_encoding(:read, "CUSTOM_WASM is not executed").category
      :unsupported_encoding
  """
  @spec unsupported_encoding(atom(), String.t(), map()) :: t()
  def unsupported_encoding(operation, message, context \\ %{})
      when is_atom(operation) and is_binary(message) and is_map(context) do
    build(:unsupported_encoding, :unsupported_encoding, operation, message, context)
  end

  @doc """
  A projected name is not a top-level field.

  ## Examples

      iex> error = F3.Error.invalid_projection(:read, "missing")
      iex> error.message
      "unknown column missing"
  """
  @spec invalid_projection(atom(), String.t()) :: t()
  def invalid_projection(operation, name)
      when is_atom(operation) and is_binary(name) do
    build(:invalid_projection, :invalid_projection, operation, "unknown column #{name}", %{
      column: name
    })
  end

  @doc """
  A chunk checksum was present and did not match the bytes.

  ## Examples

      iex> F3.Error.checksum(:read, "chunk checksum mismatch").category
      :checksum
  """
  @spec checksum(atom(), String.t()) :: t()
  def checksum(operation, message)
      when is_atom(operation) and is_binary(message) do
    build(:checksum, :checksum, operation, message, %{})
  end

  @doc """
  Row decoding needs the native library and this build does not have it.

  ## Examples

      iex> F3.Error.native_unavailable(:read).message
      "native decoder is not loaded"
  """
  @spec native_unavailable(atom()) :: t()
  def native_unavailable(operation) when is_atom(operation) do
    build(
      :native_unavailable,
      :native_unavailable,
      operation,
      "native decoder is not loaded",
      %{}
    )
  end

  @doc """
  An encoding unit could not be decoded. The message does not include file bytes.

  ## Examples

      iex> F3.Error.corrupt(:decode, "native column term is the wrong shape").category
      :corrupt
  """
  @spec corrupt(atom(), String.t()) :: t()
  def corrupt(operation, message)
      when is_atom(operation) and is_binary(message) do
    build(:corrupt, :corrupt, operation, message, %{})
  end

  @doc """
  A value does not fit the field type.

  ## Examples

      iex> F3.Error.invalid_type(:writer_write, "id is not an integer").category
      :invalid_type
  """
  @spec invalid_type(atom(), String.t()) :: t()
  def invalid_type(operation, message)
      when is_atom(operation) and is_binary(message) do
    build(:invalid_type, :invalid_type, operation, message, %{})
  end

  @doc """
  A size field is above the caller's allocation cap. A timed-out request
  uses this category as well.

  ## Examples

      iex> error = F3.Error.resource_limit(:open, "request timed out", %{timeout_ms: 10})
      iex> error.context.timeout_ms
      10
  """
  @spec resource_limit(atom(), String.t(), map()) :: t()
  def resource_limit(operation, message, context \\ %{})
      when is_atom(operation) and is_binary(message) and is_map(context) do
    build(:resource_limit, :resource_limit, operation, message, context)
  end

  defp build(reason, category, operation, message, context) do
    %__MODULE__{
      reason: reason,
      category: category,
      message: message,
      context: Map.put(context, :operation, operation)
    }
  end
end
