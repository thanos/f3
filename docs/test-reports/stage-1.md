# Stage 1 test report

Recorded 2026-11-03 after the commands below. CI has not run. Linux x86_64 is configured in `.github/workflows/ci.yml` and is untested here.

## Environment

| Tool | Version |
| --- | --- |
| Host | Darwin arm64 |
| Elixir | 1.20.2, compiled with Erlang/OTP 28 |
| OTP | 28, erts 16.2 |
| Upstream | `bd92506447dc1333820cfe9a34ebbf497fe0219e` |

The eight `.f3` fixtures were not regenerated. Their SHA-256 values are still the ones in `test/fixtures/manifest.json`. `small.f3` is 4168 bytes, SHA-256 `6f1ff9d7202c3f0d8f910a4ef154ba195cd225804d261ca752339cc8fc123a13`.

## Commands

```text
mix format
mix compile --warnings-as-errors
mix test
30 passed (3 doctests, 27 tests)
mix format --check-formatted
mix docs
mix f3.inspect test/fixtures/small.f3
mix f3.inspect test/fixtures/small.f3 --detail
mix run examples/tutorial_02.exs
mix run examples/tutorial_03.exs
```

`mix format --check-formatted` exited 0. `mix docs` wrote `doc/index.html`. `mix test` does not compile Rust. The golden comparison inside `test/f3/metadata_test.exs` matched `F3.Metadata.to_map/1` to `test/fixtures/golden/*.json` for all eight fixtures. Those JSON files were produced by one local run of `scripts/fixtures/dump_metadata.sh` against the already-built pinned reader. That script is not part of `mix test`.

## Not measured

No throughput, RSS, or scheduler numbers. Linux x86_64 and Linux arm64 were not executed. The GitHub Actions file is present and has not been run from this machine. Checksums were not recomputed. Wasm bytes were not read.

## Implemented

`F3.Postscript` reads the 32-byte tail. A short file is `:truncated`. A bad magic is `:invalid_magic`. A version other than 0.1 is `:unsupported_version`. Footer compression other than uncompressed is `:unsupported_encoding`. A claimed metadata or footer size above `max_metadata_bytes:` (default 16 MiB) is `:resource_limit` and is not allocated. Checksum type 0 is `:xxhash`. Any other byte is `{:unknown, byte}`. Both u64 checksums are stored and not verified.

`F3.FlatBuffer` walks the footer and the Arrow IPC schema message with bounds, a depth cap, and a visit cap. `F3.Footer` fills `F3.Schema`, `F3.Metadata`, and `F3.RowGroup` from the footer and from each out-of-band column-metadata root. `F3.schema/1`, `F3.metadata/1`, and `F3.inspect/2` return `{:ok, _}` for the eight fixtures. `mix f3.inspect` prints the text. JSON inspection uses Elixir `JSON` and the same decoded fields. It does not include raw footer bytes.

The Elixir maps match the upstream reader on `small`, `nullable`, `wide`, `multi_row_group`, `compressed_zstd`, `compressed_lz4`, `dictionary` (`LocalDictionary`), and `nested` (struct and list). An empty row-group vector is covered by a synthetic footer inside `test/f3/metadata_test.exs`, not by a new `.f3` file. No Rust FlatBuffers bridge was added.

## Public API

```elixir
{:ok, file} = F3.open("test/fixtures/small.f3")
{:ok, schema} = F3.schema(file)
{:ok, metadata} = F3.metadata(file)
{:ok, text} = F3.inspect(file)
{:ok, detail} = F3.inspect(file, detail: true)
{:ok, json} = F3.inspect(file, format: :json)
{:error, %F3.Error{category: :not_implemented}} = F3.read(file)
{:error, %F3.Error{category: :not_implemented}} = F3.stream(file)
{:ok, file} = F3.close(file)
{:error, %F3.Error{category: :closed}} = F3.schema(file)
```

`schema/2`, `metadata/2`, and `inspect/2` take `max_metadata_bytes:`. `F3.Writer` and `F3.Batch.to_rows/1` still return `:not_implemented`. `close/1` returns the handle that must be used afterwards.

## Documentation

Tutorial 2 stays technically reviewed. Its hex dump is unchanged. The inspect text is the output of `mix run examples/tutorial_02.exs`. Tutorial 3 is a draft, with `examples/tutorial_03.exs`. Nothing was posted. `docs/tutorials/publication-plan.md` does not schedule a post.

## Next stage

Stage 2 is row decoding: Vortex `CASCADE` values for the types in these fixtures, projection, and `F3.stream/2`. Wasm execution stays off. Checksum verification is still not part of that gate unless the stage says so.
