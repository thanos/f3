# F3 tutorials

Nine articles are planned. Stage 0 writes the first two and leaves the rest as a backlog. A backlog entry has no file. Do not treat a missing file as a finished article.

| # | Title | Status | File |
| --- | --- | --- | --- |
| 1 | Why another file format? Introducing F3 | technically reviewed | [01-why-f3.md](01-why-f3.md) |
| 2 | Anatomy of an F3 file | technically reviewed | [02-anatomy-of-an-f3-file.md](02-anatomy-of-an-f3-file.md) |
| 3 | Your first F3 file in Elixir | backlog | none until Stage 1 |
| 4 | Reading large data without overwhelming the BEAM | backlog | none until Stage 2 |
| 5 | Writing F3 from Elixir | backlog | none until Stage 4 |
| 6 | Taking the decoder with the data | backlog | none until Stage 3 |
| 7 | F3, Apache Arrow, and Parquet | backlog | none until Stage 5 |
| 8 | Building a safe binary-file reader on the BEAM | backlog | none until Stage 5 |
| 9 | Performance, compatibility, and what remains experimental | backlog | none until Stage 5 |

"Technically reviewed" means the claims were checked against the pinned upstream commit and the SIGMOD 2025 paper. It does not mean "ready to publish". Tutorial 2's hex dump is the output of `mix run examples/tutorial_02.exs`. Tutorial 3's IEx session does not exist yet, so tutorial 2 does not invent one.

## Suggested order

1. Why the format exists, and what this library refuses to claim.
2. The byte layout, from the magic backward.
3. Open a fixture in IEx, once metadata decoding works.
4. Streams and projection, once a reader exists.
5. Writing, once a writer exists.
6. Wasm, only after execution is opt-in and tested.
7. How F3 relates to Arrow and Parquet, with measurements only if they were run.
8. How the reader was kept safe.
9. What is still experimental, with the benchmark script and the machines that ran it.

## Prerequisites

Articles 1 and 2 need no Elixir beyond `mix run` from this repository. They do not need Rust. Regenerating fixtures needs the nightly toolchain named in [../upstream-compatibility.md](../upstream-compatibility.md).

## Publication checklist

- Commands in articles 1 and 2 match `examples/tutorial_01.exs` and `examples/tutorial_02.exs`, and `test/examples_test.exs` runs both.
- Numbers in the hex dump come from the script. The fixture SHA-256 is in `test/fixtures/manifest.json`.
- Paper sentences about Wasm size and Wasm-versus-native speed stay attributed to the paper.
- No article says this library reads rows.
- Relative links work in the repository. A later publishing pass has to rewrite them for a blog. That pass is described in [publication-plan.md](publication-plan.md). Nothing has been posted.
