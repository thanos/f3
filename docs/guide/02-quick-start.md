# Quick start

Add the library as a path dependency. Hex has not published it.

```elixir
def deps do
  [
    {:f3, path: "path/to/f3"}
  ]
end
```

Elixir 1.20 and OTP 28 are the versions this tree is developed on. You do not start an application. There is no supervision tree.

Open the committed fixture from the repository root, print the schema, and close the handle:

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, schema} = F3.schema(file)
{:ok, text} = F3.inspect(file)
{:ok, file} = F3.close(file)
```

`small.f3` has three rows and one row group. The fields are `trade_id` (`int64`), `symbol` (`utf8`), and `price` (`float64`). None of them are nullable. `F3.inspect/2` prints that summary. It does not read the row payload, and it does not run Wasm.

The same summary from the shell:

```shell
mix f3.inspect test/fixtures/small.f3
```

Reading the rows needs the native decoder. With that decoder compiled, the call is:

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, [batch]} = F3.read(file)
{:ok, rows} = F3.Batch.to_rows(batch)
{:ok, file} = F3.close(file)
```

`rows` is a list of maps, one per row, keyed by the field name. On a build without the native decoder, `F3.read/2` returns `{:error, %F3.Error{category: :native_unavailable}}`. The schema and inspect calls above still succeed. [Configuration](03-configuration.md) shows how to compile the decoder and how to choose a source.
