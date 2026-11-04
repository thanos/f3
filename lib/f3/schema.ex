defmodule F3.Schema do
  @moduledoc """
  Logical Arrow schema read from an F3 footer.

  A field type is a nested term. Primitive widths that the committed
  fixtures use are `{:int, width, signed?}` and `{:float, precision}`.
  `{:list, field}` and `{:struct, fields}` carry their children. Any other
  Arrow type id is `{:unsupported, id}` and does not by itself reject the file.

  Row values are not part of this struct. `F3.read/2` returns batches whose columns use these field names.
  """

  @type arrow_type ::
          :null
          | :bool
          | :utf8
          | :binary
          | {:int, pos_integer(), boolean()}
          | {:float, :half | :single | :double}
          | {:list, field()}
          | {:struct, [field()]}
          | {:unsupported, non_neg_integer()}

  @type field :: %{
          required(:name) => String.t(),
          required(:type) => arrow_type(),
          required(:nullable) => boolean()
        }

  @type t :: %__MODULE__{fields: [field()]}

  defstruct fields: []

  @doc """
  Short type name used by `F3.inspect/2`.
  """
  @spec type_label(arrow_type()) :: String.t()
  def type_label(:null), do: "null"
  def type_label(:bool), do: "bool"
  def type_label(:utf8), do: "utf8"
  def type_label(:binary), do: "binary"
  def type_label({:int, width, true}), do: "int#{width}"
  def type_label({:int, width, false}), do: "uint#{width}"
  def type_label({:float, :half}), do: "float16"
  def type_label({:float, :single}), do: "float32"
  def type_label({:float, :double}), do: "float64"
  def type_label({:list, field}), do: "list<#{type_label(field.type)}>"

  def type_label({:struct, fields}) do
    inner =
      Enum.map_join(fields, ", ", fn field -> "#{field.name}: #{type_label(field.type)}" end)

    "struct<#{inner}>"
  end

  def type_label({:unsupported, id}), do: "unsupported(#{id})"

  @doc """
  JSON-ready form of one field. Keys are strings.
  """
  @spec field_map(field()) :: map()
  def field_map(field) do
    %{
      "name" => field.name,
      "nullable" => field.nullable,
      "type" => type_map(field.type)
    }
  end

  defp type_map({:list, field}), do: %{"list" => field_map(field)}
  defp type_map({:struct, fields}), do: %{"struct" => Enum.map(fields, &field_map/1)}
  defp type_map({:unsupported, id}), do: %{"unsupported" => id}
  defp type_map(type), do: type_label(type)
end
