# Configuration

There is no application environment to set for a normal read. You pass options to `F3.open/2`, `F3.read/2`, `F3.stream/2`, and `F3.Writer.open/2`.

## Source

A path opens the local file:

```elixir
{:ok, file} = F3.open("trades.f3")
```

A memory source does not touch the path. You can pass the binary as the source option, or as the only argument:

```elixir
{:ok, file} = F3.open("unused", source: {:memory, binary})
{:ok, file} = F3.open({:memory, binary})
```

An HTTP source is opt-in. The path is not opened. The library sends one `HEAD` to learn the length, then one ranged `GET` per read. Redirects are refused. Footer `lib_urls` are not requested.

```elixir
{:ok, file} = F3.open("unused", source: {:http, url})
{:ok, file} = F3.open("unused", source: {:http, url, http_opts})
```

`http_opts` may include:

- `headers:` — a list of header pairs sent on `HEAD` and `GET`
- `timeout_ms:` — a positive integer, default 10_000
- `sign:` — a function `(method, url, headers) -> {:ok, headers} | {:error, %F3.Error{}}`

To sign a path-style S3 or MinIO object, pass all of `endpoint:`, `bucket:`, `key:`, `region:`, `access_key:`, and `secret_key:`. The request URL is `endpoint/bucket/key`. Combining `sign:` with those keys is an error. A partial key set is an error. The secret is not stored on `%F3.Error{}` and is not printed by `Inspect`.

## Read options

`F3.read/2` and `F3.stream/2` take the same options:

- `columns:` — logical field names. Omit it to read every top-level field. An unknown name is `:invalid_projection`.
- `row_groups:` — zero-based indexes. Omit it to read every row group. An index past the footer is `:invalid_argument`.
- `batch_size:` — a positive integer. The default is 8192 rows.
- `wasm:` — `:off` (the default) or `:sandbox`.
- `extensions:` — the pid from `F3.Registry.start_link/1`.
- `wasm_module_bytes:` — the module size cap. The default is 1 MiB. The hard ceiling is 16 MiB.

`F3.schema/1`, `F3.metadata/1`, and `F3.inspect/2` take `max_metadata_bytes:`. The default is 16_777_216. A claimed footer larger than that cap is `:resource_limit` and is not allocated. `F3.inspect/2` also takes `detail:` (a boolean) and `format:` (`:text` or `:json`).

## Writer options

`F3.Writer.open/2` takes:

- `schema:` — a keyword list or an `%F3.Schema{}`. Required.
- `compression:` — `:uncompressed` (the default), `:zstd`, or `:lz4`.
- `row_group_rows:` — start a new row group after at least this many rows.
- `iounit_bytes:` — default 8 MiB. A value above 64 MiB is `:resource_limit`.
- `checksum:` — `true` stores a per-IOUnit xxHash. The default is `false`.

A bare type such as `:int64` is non-null. `{type, null: true}` is nullable. An unknown option, including `source:`, is `:invalid_argument` and creates no file.

## Native decoder

Row reads and local writes need a native build. Metadata inspection does not.

```shell
F3_BUILD_NATIVE=1 mix compile
```

The decoder and the writer use two different Rust nightlies. The commands, and what each nightly is for, are in [Building from source](../contributing.md). Without that build, `F3.read/2` returns `:native_unavailable` and a valid `F3.Writer.open/2` returns `:not_implemented`. Neither call creates a file or reads the payload.
