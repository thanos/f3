# Security

Upstream F3 is a research prototype. This library is experimental. Treat every `.f3` file as untrusted input.

## What Stage 0 enforces

- `pread/3` returns at most the requested length, and never more bytes than remain after the offset captured at open. A read at or past the end returns an empty binary. It does not raise.
- `F3.Error` messages and context carry a path, an operation, or an Erlang reason atom. They do not carry file bytes. Contract tests use a marker string and reject it in the error and in `inspect/1` of a memory handle.
- `Inspect` for `F3.File`, `F3.IO.Local`, and `F3.IO.Memory` prints the origin, size, and closed flag. It does not print the buffer.
- `F3.stream/2` returns before any read.
- No code fetches a URL from metadata. The schema's `lib_urls` field is not interpreted.
- No Wasm module is compiled or executed. The native scaffold has no file or network API.
- There is no global size registry. The caller passes the maximum read length.

## What Stage 1 enforces

- The postscript is read as exactly 32 bytes. A shorter file is `:truncated`. Magic other than `F3` is `:invalid_magic`. A version other than 0.1 is `:unsupported_version`.
- Metadata size and footer size are checked against the file length, against each other, and against `max_metadata_bytes:` before any buffer of that size is allocated. The default cap is 16 MiB. An over-cap claim is `:resource_limit`. The cap is an argument to `schema/1`, `metadata/1`, and `inspect/2`.
- Footer compression other than uncompressed is `:unsupported_encoding`. Nothing is decompressed.
- Checksum type `0` is reported as `:xxhash`. Any other byte is `{:unknown, byte}`. The library does not panic and does not recompute either checksum.
- FlatBuffers offsets are checked against the buffer. A cyclic offset hits the visit cap and returns `:corrupt_metadata`. Column-metadata slices must sit strictly before the footer, inside the metadata span. A pointer into the footer or the postscript is `:corrupt_metadata`.
- Optional Wasm sections are names and file offsets. The bytes are not read, `lib_urls` is not fetched, and nothing is executed.
- Error messages do not include file bytes. A corrupt-footer test checks that a column name from the file does not appear in the message.
- Metadata inspection does not decode encoding units.

## What Stage 2 enforces

- `read/2` and `stream/2` return `:native_unavailable` when the NIF was not compiled. They do not scan payloads in that build.
- The decoder NIF is `DirtyCpu`. It does not link `fff-poc` and it does not install a global allocator. A panic or a corrupt unit becomes `{:error, %F3.Error{}}`. It does not kill the caller.
- Zstd and Lz4 are decompressed inside that NIF. The result is an owned Elixir term. Arrow buffers do not cross the boundary.
- `CUSTOM_WASM` and a shared dictionary are `:unsupported_encoding`. The bytes are not read and not executed.
- A chunk checksum is recomputed only when the footer stored one. The eight fixtures store none. Postscript checksums stay reported and unverified.
- Error messages from the NIF are stripped of control characters and capped at 180 characters. They do not include the payload.

## What later stages must keep

- Embedded Wasm stays off unless the caller opts in. A module URL in the file is data, not a download.
- A NIF must not install a process-global allocator and must not run long decompression on a normal scheduler. The Stage 2 decoder stays on the dirty CPU scheduler.
- Errors continue to omit payloads and secrets.
- Postscript checksums stay unverified. Chunk checksums are checked only when the footer field is present.

Malformed-input tests cover a truncated tail, a bad magic, a bad version, sizes past the file, a size over the cap, an unknown checksum byte, a corrupt footer root, a corrupt vtable, and a corrupt column-metadata pointer. A fixed-seed corpus of random binaries must return `{:error, %F3.Error{}}`. This is not a fuzzer.
