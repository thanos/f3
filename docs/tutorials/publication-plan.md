# Publication plan

Nothing in this file is scheduled, submitted, or posted. It is a backlog for a possible later series on a personal blog or an Elixir publication.

## Order and summaries

| # | Title | Subtitle | Tags |
| --- | --- | --- | --- |
| 1 | Why another file format? Introducing F3 | What the SIGMOD 2025 paper actually argues | elixir, parquet, file-formats |
| 2 | Anatomy of an F3 file | The 32-byte tail, then the footer | elixir, binary, flatbuffers |
| 3 | Your first F3 file in Elixir | Open, inspect, and read three rows | elixir, iex |
| 4 | Streaming and column projection | Batches, projection, and when not to call `to_rows` | elixir, streaming |
| 5 | Writing F3 from Elixir | Schema, compression, and a round trip | elixir, arrow |
| 6 | Taking the decoder with the data | Wasm, trust, and what stays off | elixir, webassembly |
| 7 | F3, Apache Arrow, and Parquet | Three different jobs | arrow, parquet |
| 8 | Building a safe binary-file reader on the BEAM | Bounds, NIFs, and a bug that the tests still catch | elixir, rustler |
| 9 | Performance, compatibility, and what remains experimental | Numbers only from a recorded run | elixir, benchmarks |

Articles 1–9 exist as technically reviewed drafts. None are `ready to publish`. Nothing here is scheduled.

## Canonical links

When a post exists, its canonical URL should point at one place, not at both the blog and a mirror. This repository can keep the Markdown source. Do not invent that URL now.

## Diagrams

| Article | Diagram | Form |
| --- | --- | --- |
| 1 | File regions: data, Wasm, column metadata, footer, postscript | Mermaid in the article |
| 2 | Postscript fields, then footer, then data | Mermaid in the article |
| 3 | Open, postscript, footer, then rows | Mermaid in the article |
| 4 | Stream, project, take one batch | prose; no benchmark table |
| 5 | Open, write, rename, read | Mermaid in the article |
| 6 | Wasm stays off, then one sandboxed call | Mermaid in the article |
| 7 | Arrow, Parquet, and F3 as three jobs | Mermaid in the article |
| 8 | Open, cap, pread, dirty CPU NIF | Mermaid in the article |
| 9 | Recorded bench output | the script output in the article; no separate diagram |

No external images. A text description sits next to each Mermaid block in the article itself.

## Checklist before any post

- Status on the article is `ready to publish`, not `technically reviewed` or `draft`.
- The example script still exits 0 at the git revision being published.
- Hex dump and any benchmark table have a command in the repository that regenerates them.
- The experimental section names the upstream SHA and says whether row reads exist.
- Links that use repository-relative paths are rewritten for the host, or the host renders them.
- The prototype warning remains in the first screen of article 1.
- The author has explicitly asked to publish. This plan is not that request.
