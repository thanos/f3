defmodule F3.Batch do
  @moduledoc """
  Columnar batch.

  `columns` is a map of column name to a columnar Elixir term. This is not
  a list of row maps. `to_rows/1` is the convenience adapter and is not
  implemented. Stage 0 has no decoder, so `F3.read/2` does not produce batches.
  """

  @type t :: %__MODULE__{
          columns: %{optional(String.t()) => term()},
          num_rows: non_neg_integer(),
          schema: F3.Schema.t() | nil
        }

  defstruct columns: %{}, num_rows: 0, schema: nil

  @doc """
  Materializes a batch as row maps.

  This returns `:not_implemented` until a reader can produce a real batch.
  """
  @spec to_rows(t()) :: {:error, F3.Error.t()}
  def to_rows(%__MODULE__{}) do
    {:error, F3.Error.not_implemented(:batch_to_rows)}
  end

  def to_rows(_batch) do
    {:error, F3.Error.invalid_argument(:batch_to_rows, "expected an F3.Batch")}
  end
end
