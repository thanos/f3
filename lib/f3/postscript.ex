defmodule F3.Postscript do
  @moduledoc """
  The 32-byte tail of an F3 file.

  Fields are little-endian, in the order fixed by `F3.Format.postscript_layout/0`.
  The magic `F3` is last. This module checks the tail and the claimed sizes.
  It does not decode the footer and it does not verify checksums.

  `metadata_size` and `footer_size` are attacker-controlled. A claim larger
  than `max_metadata_bytes` is `:resource_limit` and is not allocated.
  The default cap is 16 MiB. Pass a non-negative integer to `decode/2`
  to use another cap for that call.
  """

  alias F3.Error

  @max_metadata_bytes 16 * 1024 * 1024
  @operation :postscript

  @enforce_keys [
    :metadata_size,
    :footer_size,
    :footer_compression,
    :checksum_type,
    :data_checksum,
    :schema_checksum,
    :major_version,
    :minor_version,
    :metadata_offset,
    :footer_offset,
    :file_size
  ]
  defstruct [
    :metadata_size,
    :footer_size,
    :footer_compression,
    :checksum_type,
    :data_checksum,
    :schema_checksum,
    :major_version,
    :minor_version,
    :metadata_offset,
    :footer_offset,
    :file_size
  ]

  @type checksum_type :: :xxhash | {:unknown, 0..255}
  @type compression :: :uncompressed

  @type t :: %__MODULE__{
          metadata_size: non_neg_integer(),
          footer_size: non_neg_integer(),
          footer_compression: compression(),
          checksum_type: checksum_type(),
          data_checksum: non_neg_integer(),
          schema_checksum: non_neg_integer(),
          major_version: non_neg_integer(),
          minor_version: non_neg_integer(),
          metadata_offset: non_neg_integer(),
          footer_offset: non_neg_integer(),
          file_size: non_neg_integer()
        }

  @doc """
  Default maximum metadata span, in bytes, for one `decode/2` call.
  """
  @spec max_metadata_bytes() :: pos_integer()
  def max_metadata_bytes, do: @max_metadata_bytes

  @doc """
  Reads and checks the postscript of an open file.

  `max_metadata_bytes` limits `metadata_size` and `footer_size`. Checksum
  type `0` is `:xxhash`. Any other byte is `{:unknown, byte}` and is not
  a reason to stop. Footer compression other than uncompressed is
  `:unsupported_encoding`.
  """
  @spec decode(F3.File.t(), non_neg_integer()) :: {:ok, t()} | {:error, Error.t()}
  def decode(%F3.File{source_module: module, source_state: state}, max)
      when is_integer(max) and max >= 0 do
    with {:ok, size} <- module.size(state),
         :ok <- long_enough(size),
         {:ok, tail} <- read_exact(module, state, size - F3.Format.postscript_size(), 32) do
      parse(tail, size, max)
    end
  end

  def decode(%F3.File{}, _max) do
    {:error,
     Error.invalid_argument(@operation, "max metadata bytes must be a non-negative integer")}
  end

  defp long_enough(size) when size >= 32, do: :ok

  defp long_enough(_size) do
    {:error, Error.truncated(@operation, "file is shorter than the 32 byte postscript")}
  end

  defp read_exact(module, state, offset, length) do
    case module.pread(state, offset, length) do
      {:ok, binary} when byte_size(binary) == length ->
        {:ok, binary}

      {:ok, _short} ->
        {:error, Error.truncated(@operation, "postscript read was shorter than 32 bytes")}

      {:error, %Error{}} = error ->
        error
    end
  end

  defp parse(tail, file_size, max) do
    <<metadata_size::little-32, footer_size::little-32, footer_compression::8, checksum_type::8,
      data_checksum::little-64, schema_checksum::little-64, major::little-16, minor::little-16,
      magic::binary-size(2)>> = tail

    with :ok <- magic(magic),
         :ok <- version(major, minor),
         :ok <- compression(footer_compression),
         :ok <- cap(metadata_size, footer_size, max),
         :ok <- span(metadata_size, footer_size, file_size) do
      postscript_end = file_size - F3.Format.postscript_size()

      {:ok,
       %__MODULE__{
         metadata_size: metadata_size,
         footer_size: footer_size,
         footer_compression: :uncompressed,
         checksum_type: checksum(checksum_type),
         data_checksum: data_checksum,
         schema_checksum: schema_checksum,
         major_version: major,
         minor_version: minor,
         metadata_offset: postscript_end - metadata_size,
         footer_offset: postscript_end - footer_size,
         file_size: file_size
       }}
    end
  end

  defp magic("F3"), do: :ok
  defp magic(_other), do: {:error, Error.invalid_magic(@operation)}

  defp version(major, minor) do
    if F3.Format.compatible?(major, minor) do
      :ok
    else
      {:error, Error.unsupported_version(@operation, major, minor)}
    end
  end

  defp compression(0), do: :ok

  defp compression(byte) do
    {:error,
     Error.unsupported_encoding(
       @operation,
       "footer compression #{byte} is not uncompressed",
       %{footer_compression: byte}
     )}
  end

  defp cap(metadata_size, footer_size, max) do
    if metadata_size > max or footer_size > max do
      {:error,
       Error.resource_limit(
         @operation,
         "metadata size exceeds the #{max} byte cap",
         %{metadata_size: metadata_size, footer_size: footer_size, max_metadata_bytes: max}
       )}
    else
      :ok
    end
  end

  defp span(metadata_size, footer_size, file_size) do
    room = file_size - F3.Format.postscript_size()

    cond do
      footer_size == 0 or metadata_size == 0 ->
        {:error, Error.corrupt_metadata(@operation, "footer size is empty")}

      footer_size > metadata_size ->
        {:error,
         Error.corrupt_metadata(@operation, "footer is larger than the metadata span", %{
           metadata_size: metadata_size,
           footer_size: footer_size
         })}

      metadata_size > room ->
        {:error,
         Error.truncated(@operation, "metadata size extends past the start of the file", %{
           metadata_size: metadata_size,
           file_size: file_size
         })}

      true ->
        :ok
    end
  end

  defp checksum(0), do: :xxhash
  defp checksum(byte), do: {:unknown, byte}
end
