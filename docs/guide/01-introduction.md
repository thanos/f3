# Introduction

F3 is a columnar file format for research. This library, version 0.1.0, opens those files from Elixir, prints the schema and footer, and reads or writes rows when the native decoder is compiled.

An F3 file stores columns, not a list of row records. The end of the file is a 32-byte postscript. That tail points at a footer. The footer holds an Arrow schema, row groups, and the locations of the column bytes. The only wire version this library accepts is major 0, minor 1.

You can open three kinds of source:

- a path on the local disk
- a binary already in memory
- an HTTP URL, if you opt in

`F3.schema/1`, `F3.metadata/1`, and `F3.inspect/2` work on every build. `F3.read/2` and `F3.stream/2` decode CASCADE data when the native decoder is compiled. `F3.Writer` writes a local file in that same build. Wasm runs only when a read passes `wasm: :sandbox`.

This library does not write to a remote URL. It does not fetch footer `lib_urls`. It does not follow HTTP redirects. It does not load shared dictionaries. It does not claim signed `int8` or `int16`, `float16`, plain binary, decimal, dates, timestamps, maps, or Arrow dictionary columns.

Hex has not published this package. Add the repository as a path dependency until a release exists. The [quick start](02-quick-start.md) opens a committed fixture. [Status and roadmap](11-status-and-roadmap.md) lists what 0.1.0 includes.
