defmodule F3.Format do
  @moduledoc """
  Pinned wire-format constants from upstream F3.

  These values were read from `fff-format/src/lib.rs` and `format/File.fbs`
  at commit `bd92506447dc1333820cfe9a34ebbf497fe0219e`. This module does not
  parse a file. Postscript decoding is Stage 1.

  The postscript is 32 little-endian bytes at the end of the file. The two
  magic bytes `F3` are last.
  """

  @upstream_sha "bd92506447dc1333820cfe9a34ebbf497fe0219e"
  @magic "F3"
  @postscript_size 32
  @major_version 0
  @minor_version 1

  @typedoc "Field name and width in bytes, from the start of the postscript."
  @type layout_field :: {atom(), pos_integer()}

  @doc """
  Full upstream commit this build is compatible with.
  """
  @spec upstream_sha() :: String.t()
  def upstream_sha, do: @upstream_sha

  @doc """
  Two-byte magic that terminates a file.
  """
  @spec magic() :: <<_::16>>
  def magic, do: @magic

  @doc """
  Postscript length in bytes, including the magic.
  """
  @spec postscript_size() :: 32
  def postscript_size, do: @postscript_size

  @spec major_version() :: 0
  def major_version, do: @major_version

  @spec minor_version() :: 1
  def minor_version, do: @minor_version

  @doc """
  Postscript fields in file order. Widths sum to `postscript_size/0`.

  Integer fields are little-endian. `:magic` is the raw bytes `F3`.
  """
  @spec postscript_layout() :: [layout_field()]
  def postscript_layout do
    [
      {:metadata_size, 4},
      {:footer_size, 4},
      {:footer_compression, 1},
      {:checksum_type, 1},
      {:data_checksum, 8},
      {:schema_checksum, 8},
      {:major_version, 2},
      {:minor_version, 2},
      {:magic, 2}
    ]
  end

  @doc """
  Whether this build accepts a wire version.

  Only major 0 and minor 1, the pair pinned from upstream, is accepted.
  Any other pair is unsupported until a version adapter exists.

  ## Examples

      iex> F3.Format.compatible?(0, 1)
      true

      iex> F3.Format.compatible?(1, 0)
      false

      iex> F3.Format.compatible?(0, 2)
      false
  """
  @spec compatible?(integer(), integer()) :: boolean()
  def compatible?(major, minor)
      when is_integer(major) and is_integer(minor) and major >= 0 and minor >= 0 do
    major == @major_version and minor == @minor_version
  end

  def compatible?(_major, _minor), do: false
end
