# F3 tutorials

Nine articles are in the tree. A missing file would be a backlog entry. Do not treat a missing file as a finished article. Runnable API examples for library version `0.1.0` are in `docs/examples.livemd`.

| # | Title | Status | File |
| --- | --- | --- | --- |
| 1 | Why another file format? Introducing F3 | technically reviewed | [01-why-f3.md](01-why-f3.md) |
| 2 | Anatomy of an F3 file | technically reviewed | [02-anatomy-of-an-f3-file.md](02-anatomy-of-an-f3-file.md) |
| 3 | Your first F3 file in Elixir | technically reviewed | [03-your-first-f3-file-in-elixir.md](03-your-first-f3-file-in-elixir.md) |
| 4 | Streaming and column projection | technically reviewed | [04-streaming-and-column-projection.md](04-streaming-and-column-projection.md) |
| 5 | Writing F3 from Elixir | technically reviewed | [05-writing-f3-from-elixir.md](05-writing-f3-from-elixir.md) |
| 6 | Taking the decoder with the data | technically reviewed | [06-custom-encodings-and-wasm.md](06-custom-encodings-and-wasm.md) |
| 7 | F3, Apache Arrow, and Parquet | technically reviewed | [07-f3-arrow-and-parquet.md](07-f3-arrow-and-parquet.md) |
| 8 | Building a safe binary-file reader on the BEAM | technically reviewed | [08-a-safe-reader-on-the-beam.md](08-a-safe-reader-on-the-beam.md) |
| 9 | Performance, compatibility, and what remains experimental | technically reviewed | [09-performance-and-what-remains-experimental.md](09-performance-and-what-remains-experimental.md) |

"Technically reviewed" means the claims were checked against the pinned upstream commit and the SIGMOD 2025 paper. It does not mean "ready to publish". Tutorial 2's hex dump and inspect text are the output of `mix run examples/tutorial_02.exs`. Tutorials 3 and 4 print the native row output when `F3_BUILD_NATIVE=1`. The default build prints that the decoder is not loaded. Tutorial 5 prints that the writer is not loaded in that same default build. Tutorial 9 quotes `docs/test-reports/stage-5.md` and does not add numbers of its own.

## Suggested order

1. Why the format exists, and what this library refuses to claim.
2. The byte layout, from the magic backward.
3. Open a fixture, print the schema, and read `small.f3` when the native decoder is loaded.
4. Stream a file, project columns, and keep batches columnar.
5. Write a local file and read it back.
6. Wasm, only after execution is opt-in and tested.
7. How F3 relates to Arrow and Parquet, with measurements only if they were run.
8. How the reader was kept safe.
9. What is still experimental, with the benchmark script and the machines that ran it.

## Prerequisites

Articles 1 and 2 need no Elixir beyond `mix run` from this repository. They do not need Rust. Regenerating fixtures needs the nightly toolchain named in [../upstream-compatibility.md](../upstream-compatibility.md).

## Publication checklist

- Commands in articles 1–9 match `examples/tutorial_01.exs` through `examples/tutorial_09.exs`. `test/examples_test.exs` runs them.
- Numbers in the hex dump come from the script. The fixture SHA-256 is in `test/fixtures/manifest.json`.
- Paper sentences about Wasm size and Wasm-versus-native speed stay attributed to the paper.
- Articles 3 and 4 say row reads need the native decoder. Article 3 also prints that the writer is not loaded unless that build is on. They do not claim Wasm execution.
- Relative links work in the repository. A later publishing pass has to rewrite them for a blog. That pass is described in [publication-plan.md](publication-plan.md). Nothing has been posted.
