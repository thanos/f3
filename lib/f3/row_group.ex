defmodule F3.RowGroup do
  @moduledoc """
  One row group, with the column chunks the footer points at.

  `columns` follows the column-metadata order for that row group. `name`
  is the matching schema field when the counts line up, and `nil` when
  they do not. Chunks are IOUnits. Each `encunits` entry is one encoding
  unit. This struct does not contain column bytes.
  """

  @type dictionary ::
          :none
          | {:local, [non_neg_integer()]}
          | {:shared, non_neg_integer()}

  @type encoding :: :cascade | :custom_wasm | non_neg_integer()
  @type compression :: :uncompressed | :zstd | :lz4 | non_neg_integer()

  @type encunit :: %{
          required(:size) => non_neg_integer(),
          required(:num_rows) => non_neg_integer(),
          required(:encoding) => encoding(),
          required(:compression) => compression(),
          required(:wasm_id) => non_neg_integer() | nil
        }

  @type chunk :: %{
          required(:offset) => non_neg_integer(),
          required(:size) => non_neg_integer(),
          required(:num_rows) => non_neg_integer(),
          required(:dictionary) => dictionary(),
          required(:checksum) => non_neg_integer() | nil,
          required(:encunits) => [encunit()]
        }

  @type column :: %{
          required(:index) => non_neg_integer(),
          required(:name) => String.t() | nil,
          required(:chunks) => [chunk()]
        }

  @type t :: %__MODULE__{
          index: non_neg_integer(),
          num_rows: non_neg_integer(),
          byte_offset: non_neg_integer(),
          byte_size: non_neg_integer(),
          columns: [column()]
        }

  defstruct [:index, :num_rows, :byte_offset, :byte_size, columns: []]
end
