defmodule F3.Metadata do
  @moduledoc """
  File-level metadata presented to callers.

  Stage 0 does not decode the FlatBuffers footer or the out-of-band column
  metadata. `F3.metadata/1` returns
  `{:error, %F3.Error{category: :not_implemented}}`.
  """

  @type t :: %__MODULE__{
          major_version: non_neg_integer() | nil,
          minor_version: non_neg_integer() | nil,
          metadata_size: non_neg_integer() | nil,
          footer_size: non_neg_integer() | nil,
          footer_compression: atom() | nil,
          checksum_type: atom() | nil,
          row_groups: [F3.RowGroup.t()]
        }

  defstruct [
    :major_version,
    :minor_version,
    :metadata_size,
    :footer_size,
    :footer_compression,
    :checksum_type,
    row_groups: []
  ]
end
