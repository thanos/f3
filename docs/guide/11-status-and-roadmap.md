# Status and roadmap

Library version 0.1.0. The only accepted wire version is major 0, minor 1. Hex has not published this package. A tag matching that version builds precompiled NIFs for macOS Apple silicon and Linux x86_64 and can publish them. That publish has not been run. In this checkout, row reads and local writes need `F3_BUILD_NATIVE=1`.

## This version

| Area | Status |
| --- | --- |
| Open and close a local file or a memory binary | implemented |
| HTTP range read | implemented, opt-in, no redirects |
| Postscript, schema, and footer metadata | implemented |
| Read rows, project, and stream | implemented when the native decoder is compiled |
| Write a local file | implemented when the native writer is compiled |
| Embedded Wasm | opt-in with `wasm: :sandbox` |

This version includes:

- opening a local file, an in-memory binary, or an opt-in HTTP range source
- postscript and footer inspection, including schema and checksums
- row reads and streams through the Vortex decoder, with column and row-group selection
- a local writer for the types in [F3 in detail](04-f3-in-detail.md), in a separate process
- opt-in Wasm for `CUSTOM_WASM`

## Later

Still outside this version:

- the first publish to Hex (the workflow is in the repository and has not been run)
- shared dictionaries
- signed `int8` and `int16`, `float16`, plain binary, decimal, dates, timestamps, maps, and Arrow dictionary columns
- writes to a remote URL, and fetches of footer `lib_urls`
- a required MinIO job, or a benchmark gate in CI
- Linux arm64 and upstream's Intel Debian 12 image, which have not been run here

Wasm generation stays off. The writer does not gain a remote path in this version.

The [feature matrix](../feature-matrix.md) is the contributor checklist, with the test that backs each row. [Architecture](../architecture.md) is the component map.
