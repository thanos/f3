# Streaming and column projection

**Status:** technically reviewed  
**Audience:** an Elixir engineer who has opened `small.f3` with tutorial 3.  
**Estimated reading time:** 8 minutes, estimated from length, not from a timed reading.  
**Upstream pin:** `bd92506447dc1333820cfe9a34ebbf497fe0219e`

`F3.read/2` returns every selected row group before the caller sees a batch. `F3.stream/2` returns a stream and does not pread until the first pull. `Enum.take/2` stops further reads. The caller still owns `F3.close/1`.

## What a batch is

A batch is columnar. Each field name maps to an `F3.Column`. `F3.Batch.to_rows/1` zips those columns into one map per row. That is the convenience path. A large file should keep the columns. Building a map per row copies every value onto the process heap.

One native call decodes a whole encoding unit. Elixir then slices it to `batch_size` rows. The default is 8192 (`F3.Reader.default_batch_size/0`). The committed fixtures are smaller than one unit, so a row group is one batch unless `batch_size` is set lower.

The native call runs on the dirty CPU scheduler. These fixtures are too small to measure scheduler delay. This article has no latency or RSS numbers.

## Project, then take

`columns:` is a list of logical field names. An unknown name is `:invalid_projection`. Omitted means every logical field. `row_groups:` is a list of indexes. An index past the footer is `:invalid_argument`.

`test/fixtures/multi_row_group.f3` has two row groups, with 2 rows and then 1 row, and one `trade_id` column. This takes the first batch only:

```elixir
{:ok, file} = F3.open("test/fixtures/multi_row_group.f3")
{:ok, stream} = F3.stream(file, columns: ["trade_id"], batch_size: 2)
[batch] = Enum.take(stream, 1)
{:ok, rows} = F3.Batch.to_rows(batch)
{:ok, file} = F3.close(file)
```

`examples/tutorial_04.exs` prints that when the native decoder is loaded:

```text
command: mix run examples/tutorial_04.exs
batches taken: 1
batch rows: 2
columns: trade_id
to_rows of the first batch:
[%{"trade_id" => 1}, %{"trade_id" => 2}]
to_rows copies every value into a map. Keep the batch for a large file.
```

A build without the decoder prints `stream: native decoder is not loaded` and does not pread the encoding units. `mix test` is that build. Compile the decoder with `F3_BUILD_NATIVE=1 mix compile --force` on Rust `nightly-2025-11-15`, then run the script again.

The second row group stays unread after `Enum.take/2`. Closing is still the caller's job. The handle returned by `close/1` is the one that is closed.

## What is experimental?

The eight fixtures fit in one encoding unit each. They do not show how a multi-unit column is concatenated, and they are the wrong size for a scheduler measurement. `CUSTOM_WASM` and a shared dictionary are refused. The bytes are not executed. Bool and plain binary columns are not in the fixtures, so this reader does not claim them.

## Next

Tutorial 5 is writing, and it is not implemented. Tutorial 6 is Wasm, and execution stays off.

## Sources

- `F3.read/2`, `F3.stream/2`, `F3.Batch.to_rows/1`
- Example: `examples/tutorial_04.exs`
- Fixture: `test/fixtures/multi_row_group.f3`
