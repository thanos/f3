defmodule F3.Logical do
  @moduledoc """
  Stitches physical columns into logical fields.

  The footer leaves nested physical columns unnamed. This module walks the
  schema in the same order as the pinned reader: a struct consumes a boolean
  validity column and then its children, and a list consumes an offset column
  and then its child. The logical tree must describe that same shape. A
  disagreement stops the read.
  """

  @doc """
  The logical tree and the Arrow schema describe the same nesting.
  """
  @spec matches?(F3.Metadata.logical_tree() | nil, [F3.Schema.field()]) :: boolean()
  def matches?(%{id: :struct, children: children}, fields)
      when length(children) == length(fields) do
    Enum.zip(children, fields) |> Enum.all?(fn {node, field} -> field_match?(node, field) end)
  end

  def matches?(_tree, _fields), do: false

  @doc """
  Physical `{index, type}` pairs required by the named top-level fields.
  """
  @spec needed([F3.Schema.field()], [String.t()]) ::
          {:ok, [{non_neg_integer(), atom()}]} | {:error, F3.Error.t()}
  def needed(fields, names) when is_list(fields) and is_list(names) do
    case collect_fields(fields, names, 0, true) do
      {:ok, pairs, _index} -> {:ok, pairs}
      {:error, %F3.Error{}} = error -> error
    end
  end

  @doc """
  Builds logical columns for `names` from physical columns keyed by index.
  """
  @spec assemble([F3.Schema.field()], [String.t()], %{non_neg_integer() => F3.Column.t()}) ::
          {:ok, %{optional(String.t()) => F3.Column.t()}} | {:error, F3.Error.t()}
  def assemble(fields, names, physical) do
    case walk(fields, names, physical, 0, %{}) do
      {:ok, columns, _index} -> {:ok, columns}
      {:error, %F3.Error{}} = error -> error
    end
  end

  defp field_match?(%{id: :flat, children: []}, %{type: type}), do: primitive?(type)

  defp field_match?(%{id: :struct, children: children}, %{type: {:struct, fields}}) do
    matches?(%{id: :struct, children: children}, fields)
  end

  defp field_match?(%{id: :list, children: [child]}, %{type: {:list, item}}) do
    field_match?(child, item)
  end

  defp field_match?(_node, _field), do: false

  defp primitive?({:int, width, signed}) when width in [8, 16, 32, 64] and is_boolean(signed) do
    true
  end

  defp primitive?({:float, precision}) when precision in [:half, :single, :double], do: true
  defp primitive?(type) when type in [:utf8, :binary, :bool, :null], do: true
  defp primitive?(_type), do: false

  defp collect_fields(fields, names, index, top?) do
    Enum.reduce_while(fields, {:ok, [], index}, fn field, {:ok, acc, index} ->
      case collect_field(field, names, index, top?) do
        {:ok, more, index} -> {:cont, {:ok, acc ++ more, index}}
        {:error, %F3.Error{}} = error -> {:halt, error}
      end
    end)
  end

  defp collect_field(field, names, index, true) do
    if field.name in names do
      collect_field(field, names, index, false)
    else
      {:ok, [], advance(field, index)}
    end
  end

  defp collect_field(%{type: {:struct, children}}, _names, index, false) do
    case collect_fields(children, [], index + 1, false) do
      {:ok, rest, next} -> {:ok, [{index, :bool} | rest], next}
      {:error, %F3.Error{}} = error -> error
    end
  end

  defp collect_field(%{type: {:list, item}}, _names, index, false) do
    case collect_field(item, [], index + 1, false) do
      {:ok, rest, next} -> {:ok, [{index, :list32} | rest], next}
      {:error, %F3.Error{}} = error -> error
    end
  end

  defp collect_field(%{type: type}, _names, index, false) do
    case primitive_atom(type) do
      {:ok, atom} -> {:ok, [{index, atom}], index + 1}
      {:error, %F3.Error{}} = error -> error
    end
  end

  defp walk(fields, names, physical, index, acc) do
    Enum.reduce_while(fields, {:ok, acc, index}, fn field, {:ok, acc, index} ->
      step_field(field, names, physical, index, acc)
    end)
  end

  defp step_field(%{name: name} = field, names, physical, index, acc) do
    if name in names do
      case consume(field, physical, index) do
        {:ok, column, index} -> {:cont, {:ok, Map.put(acc, name, column), index}}
        {:error, %F3.Error{}} = error -> {:halt, error}
      end
    else
      {:cont, {:ok, acc, advance(field, index)}}
    end
  end

  defp consume(%{type: {:struct, children}}, physical, index) do
    names = Enum.map(children, & &1.name)

    with {:ok, flags} <- fetch(physical, index, :bool),
         {:ok, kids, next} <- consume_children(children, physical, index + 1),
         {:ok, column} <- F3.Column.struct(names, flags, kids) do
      {:ok, column, next}
    end
  end

  defp consume(%{type: {:list, item}}, physical, index) do
    with {:ok, offsets} <- fetch_list(physical, index),
         {:ok, child, next} <- consume(item, physical, index + 1),
         {:ok, column} <- F3.Column.list(offsets, child) do
      {:ok, column, next}
    end
  end

  defp consume(%{type: type}, physical, index) do
    with {:ok, atom} <- primitive_atom(type),
         {:ok, column} <- fetch(physical, index, atom) do
      {:ok, column, index + 1}
    end
  end

  defp consume_children(children, physical, index) do
    Enum.reduce_while(children, {:ok, [], index}, fn child, {:ok, acc, index} ->
      case consume(child, physical, index) do
        {:ok, column, index} -> {:cont, {:ok, [column | acc], index}}
        {:error, %F3.Error{}} = error -> {:halt, error}
      end
    end)
    |> reverse_children()
  end

  defp reverse_children({:ok, children, index}), do: {:ok, Enum.reverse(children), index}
  defp reverse_children({:error, %F3.Error{}} = error), do: error

  defp advance(%{type: {:struct, children}}, index), do: advance_fields(children, index + 1)
  defp advance(%{type: {:list, item}}, index), do: advance(item, index + 1)
  defp advance(_field, index), do: index + 1

  defp advance_fields(fields, index) do
    Enum.reduce(fields, index, fn field, index -> advance(field, index) end)
  end

  defp fetch(physical, index, atom) do
    case Map.fetch(physical, index) do
      {:ok, column} ->
        if F3.Column.matches?(column, atom) do
          {:ok, column}
        else
          {:error, F3.Error.corrupt(:read, "decoded kind does not match the schema")}
        end

      :error ->
        {:error, F3.Error.corrupt(:read, "missing physical column #{index}")}
    end
  end

  defp fetch_list(physical, index) do
    case Map.fetch(physical, index) do
      {:ok, %F3.Column{kind: kind} = column} when kind in [:list32, :list64] ->
        {:ok, column}

      {:ok, _column} ->
        {:error, F3.Error.corrupt(:read, "list offsets are not a list column")}

      :error ->
        {:error, F3.Error.corrupt(:read, "missing physical column #{index}")}
    end
  end

  defp primitive_atom({:int, 64, true}), do: {:ok, :i64}
  defp primitive_atom({:int, 32, true}), do: {:ok, :i32}
  defp primitive_atom({:int, 16, true}), do: unsupported("int16")
  defp primitive_atom({:int, 8, true}), do: unsupported("int8")
  defp primitive_atom({:int, 64, false}), do: {:ok, :u64}
  defp primitive_atom({:int, 32, false}), do: {:ok, :u32}
  defp primitive_atom({:int, 16, false}), do: {:ok, :u16}
  defp primitive_atom({:int, 8, false}), do: {:ok, :u8}
  defp primitive_atom({:float, :double}), do: {:ok, :f64}
  defp primitive_atom({:float, :single}), do: {:ok, :f32}
  defp primitive_atom({:float, :half}), do: unsupported("float16")
  defp primitive_atom(:utf8), do: {:ok, :utf8}
  defp primitive_atom(:bool), do: {:ok, :bool}
  defp primitive_atom(:binary), do: unsupported("binary")
  defp primitive_atom(:null), do: unsupported("null")
  defp primitive_atom({:unsupported, id}), do: unsupported("arrow type #{id}")
  defp primitive_atom(_type), do: unsupported("arrow type")

  defp unsupported(name) do
    {:error, F3.Error.unsupported_encoding(:read, "#{name} is not decoded")}
  end
end
