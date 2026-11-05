# F3 tutorials

Nine articles are planned. Stage 0 writes the first two and leaves the rest as a backlog. A backlog entry has no file. Do not treat a missing file as a finished article.

| # | Title | Status | File |
| --- | --- | --- | --- |
| 1 | Why another file format? Introducing F3 | technically reviewed | [01-why-f3.md](01-why-f3.md) |
| 2 | Anatomy of an F3 file | technically reviewed | [02-anatomy-of-an-f3-file.md](02-anatomy-of-an-f3-file.md) |
| 3 | Your first F3 file in Elixir | technically reviewed | [03-your-first-f3-file-in-elixir.md](03-your-first-f3-file-in-elixir.md) |
| 4 | Streaming and column projection | technically reviewed | [04-streaming-and-column-projection.md](04-streaming-and-column-projection.md) |
| 5 | Writing F3 from Elixir | backlog | none until Stage 4 |
| 6 | Taking the decoder with the data | technically reviewed | [06-custom-encodings-and-wasm.md](06-custom-encodings-and-wasm.md) |
| 7 | F3, Apache Arrow, and Parquet | backlog | none until Stage 5 |
| 8 | Building a safe binary-file reader on the BEAM | backlog | none until Stage 5 |
| 9 | Performance, compatibility, and what remains experimental | backlog | none until Stage 5 |

"Technically reviewed" means the claims were checked against the pinned upstream commit and the SIGMOD 2025 paper. It does not mean "ready to publish". Tutorial 2's hex dump and inspect text are the output of `mix run examples/tutorial_02.exs`. Tutorials 3 and 4 print the native row output when `F3_BUILD_NATIVE=1`. The default build prints that the decoder is not loaded.

## Suggested order

1. Why the format exists, and what this library refuses to claim.
2. The byte layout, from the magic backward.
3. Open a fixture, print the schema, and read `small.f3` when the native decoder is loaded.
4. Stream a file, project columns, and keep batches columnar.
5. Writing, once a writer exists.
6. Wasm, only after execution is opt-in and tested.
7. How F3 relates to Arrow and Parquet, with measurements only if they were run.
8. How the reader was kept safe.
9. What is still experimental, with the benchmark script and the machines that ran it.

## Prerequisites

Articles 1 and 2 need no Elixir beyond `mix run` from this repository. They do not need Rust. Regenerating fixtures needs the nightly toolchain named in [../upstream-compatibility.md](../upstream-compatibility.md).

## Publication checklist

- Commands in articles 1–4 and 6 match `examples/tutorial_01.exs` through `examples/tutorial_04.exs` and `examples/tutorial_06.exs`. `test/examples_test.exs` runs them.
- Numbers in the hex dump come from the script. The fixture SHA-256 is in `test/fixtures/manifest.json`.
- Paper sentences about Wasm size and Wasm-versus-native speed stay attributed to the paper.
- Articles 3 and 4 say row reads need the native decoder. They do not claim Wasm execution or a writer.
- Relative links work in the repository. A later publishing pass has to rewrite them for a blog. That pass is described in [publication-plan.md](publication-plan.md). Nothing has been posted.
