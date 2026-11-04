defmodule F3.Batch do
  @moduledoc """
  Columnar batch.

  `columns` maps a field name to an `F3.Column`. That is the storage form.
  `to_rows/1` zips those columns into maps and is the convenience path for
  a small result. A large file should keep the columns.
  """

  @type t :: %__MODULE__{
          columns: %{optional(String.t()) => term()},
          num_rows: non_neg_integer(),
          schema: F3.Schema.t() | nil
        }

  defstruct columns: %{}, num_rows: 0, schema: nil

  @doc """
  Materializes a batch as row maps.

  Keys are the logical field names. Nested values are maps and lists.
  Nulls are `nil`.
  """
  @spec to_rows(t()) :: {:ok, [map()]} | {:error, F3.Error.t()}
  def to_rows(%__MODULE__{num_rows: 0}), do: {:ok, []}

  def to_rows(%__MODULE__{schema: nil}) do
    {:error, F3.Error.invalid_argument(:batch_to_rows, "batch has no schema")}
  end

  def to_rows(%__MODULE__{num_rows: rows, schema: schema, columns: columns}) do
    materialized =
      for index <- 0..(rows - 1)//1 do
        Map.new(schema.fields, fn field ->
          {field.name, F3.Column.value(Map.fetch!(columns, field.name), index)}
        end)
      end

    {:ok, materialized}
  end

  def to_rows(_batch) do
    {:error, F3.Error.invalid_argument(:batch_to_rows, "expected an F3.Batch")}
  end
end
