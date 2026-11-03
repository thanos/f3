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

## What later stages must keep

- Size fields in the postscript and in FlatBuffers are attacker-controlled. Check them against the file length before allocating.
- Unknown versions, unknown checksum types, and truncated tails return `{:error, %F3.Error{}}`. They must not raise, and they must not follow upstream's panic on an unknown checksum byte.
- Embedded Wasm stays off unless the caller opts in. A module URL in the file is data, not a download.
- A NIF must not install a process-global allocator and must not run long decompression on a normal scheduler.
- Errors continue to omit payloads and secrets.

Stage 0 does not fuzz the format. There is no format parser yet. The source tests cover short reads, a missing path, and a closed handle.
