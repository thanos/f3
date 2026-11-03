# Runnable from the repository root:
#   mix run examples/tutorial_03.exs
#
# Opens the committed small fixture, prints schema and metadata, and shows
# that row reading is not implemented.

IO.puts("command: mix run examples/tutorial_03.exs")

{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, schema} = F3.schema(file)
{:ok, metadata} = F3.metadata(file)

IO.puts("fields:")

Enum.each(schema.fields, fn field ->
  mark = if field.nullable, do: " nullable", else: ""
  IO.puts("  #{field.name} #{F3.Schema.type_label(field.type)}#{mark}")
end)

IO.puts("row_groups: #{length(metadata.row_groups)}")
IO.puts("rows: #{Enum.reduce(metadata.row_groups, 0, fn group, acc -> acc + group.num_rows end)}")

{:error, %F3.Error{category: :not_implemented}} = F3.read(file)
IO.puts("read: not implemented")

{:ok, text} = F3.inspect(file)
IO.puts("inspect:")
IO.puts(text)

{:ok, file} = F3.close(file)
{:error, %F3.Error{category: :closed}} = F3.schema(file)
IO.puts("after close: closed")
