defmodule F3.Error do
  @moduledoc """
  Error returned by the public F3 API.

  `message` is safe to show to a caller. It does not include file bytes,
  secrets, or an underlying payload. `context` carries small identifiers
  such as a path, offset, or operation name.
  """

  @enforce_keys [:reason, :category, :message]
  defstruct [:reason, :category, :message, :cause, context: %{}]

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

  @type t :: %__MODULE__{
          reason: atom(),
          category: category(),
          message: String.t(),
          cause: term(),
          context: map()
        }

  @doc """
  Builds an error for an operation this experimental version does not perform.
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
  A local path does not exist.
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
  The file ends before a required field.
  """
  @spec truncated(atom(), String.t(), map()) :: t()
  def truncated(operation, message, context \\ %{})
      when is_atom(operation) and is_binary(message) and is_map(context) do
    build(:truncated, :truncated, operation, message, context)
  end

  @doc """
  The last two bytes are not the F3 magic.
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
  """
  @spec corrupt_metadata(atom(), String.t(), map()) :: t()
  def corrupt_metadata(operation, message, context \\ %{})
      when is_atom(operation) and is_binary(message) and is_map(context) do
    build(:corrupt_metadata, :corrupt_metadata, operation, message, context)
  end

  @doc """
  The file names an encoding this build will not decode.
  """
  @spec unsupported_encoding(atom(), String.t(), map()) :: t()
  def unsupported_encoding(operation, message, context \\ %{})
      when is_atom(operation) and is_binary(message) and is_map(context) do
    build(:unsupported_encoding, :unsupported_encoding, operation, message, context)
  end

  @doc """
  A size field is above the caller's allocation cap.
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
