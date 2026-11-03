defmodule F3.Schema do
  @moduledoc """
  Logical column schema.

  Stage 0 does not decode a schema from a file. `F3.schema/1` returns
  `{:error, %F3.Error{category: :not_implemented}}`. The struct exists so
  later stages can fill `fields` without changing the public type name.

  Each field map has `:name`, `:type`, and `:nullable`. Nested Arrow types
  are not represented until a reader demonstrates them.
  """

  @type field :: %{
          required(:name) => String.t(),
          required(:type) => atom(),
          required(:nullable) => boolean()
        }

  @type t :: %__MODULE__{fields: [field()]}

  defstruct fields: []
end
