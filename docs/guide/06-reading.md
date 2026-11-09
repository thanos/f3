# Reading

`F3.read/2` reads the selected row groups into columnar batches. One native call decodes a whole encoding unit. Elixir then slices that column to `batch_size` rows. The default is 8192. The committed fixtures are smaller than one unit, so a row group becomes one batch unless you set `batch_size` lower.

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, batches} = F3.read(file, columns: ["symbol", "price"], batch_size: 2)
{:ok, rows} = F3.Batch.to_rows(hd(batches))
{:ok, file} = F3.close(file)
```

`columns:` names top-level fields. Omit it to read every top-level field. An unknown name returns `:invalid_projection`. `row_groups:` is a list of zero-based indexes. Omit it to read every row group.

`rows` is a list of maps. Nested values are maps and lists. Nulls are `nil`. For a large file, keep `batch.columns` and skip `to_rows/1`. The keys of `batch.columns` are the field names you asked for.

These calls need the native decoder. Without it, `F3.read/2` returns `{:error, %F3.Error{category: :native_unavailable}}` and does not read the payload. `F3.schema/1` still returns the footer schema on that build.

A missing file is `:not_found`. A closed handle is `:closed`. A bad option is `:invalid_argument`. A wire version other than 0.1 is `:unsupported_version`. A short file is `:truncated`. A footer that does not describe the file is `:corrupt_metadata`. A shared dictionary is `:unsupported_encoding`. These are `{:error, %F3.Error{}}` values. They do not raise.

`CUSTOM_WASM` is `:unsupported_encoding` unless you pass `wasm: :sandbox` or register a decoder. Both are covered in [Wasm](09-wasm.md) and [Decoders](08-decoders.md). Checksums are printed by `F3.inspect/2`. A chunk checksum is verified only when the footer stored one. The eight committed fixtures store none.

`F3.stream/2` is the same selection, pulled lazily. That is the next page.
