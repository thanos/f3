defmodule F3.RowGroup do
  @moduledoc """
  One row group, once metadata decoding exists.

  Stage 0 never builds this from a file. Fields stay `nil` until Stage 1
  fills them from a decoded footer.
  """

  @type t :: %__MODULE__{
          index: non_neg_integer() | nil,
          num_rows: non_neg_integer() | nil,
          byte_offset: non_neg_integer() | nil,
          byte_size: non_neg_integer() | nil
        }

  defstruct [:index, :num_rows, :byte_offset, :byte_size]
end
