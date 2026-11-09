# Wasm

Wasm stays off until you ask for it. `F3.inspect/2`, `F3.schema/1`, and `F3.metadata/1` never execute a module. A Wasm section in the footer is an offset and a size.

```elixir
{:ok, batches} = F3.read(file, wasm: :sandbox)
```

`wasm: :off` is the default. A `CUSTOM_WASM` unit then returns `:unsupported_encoding` and the module bytes are not read. `wasm: :sandbox` is the only other accepted value. It runs that module for the encoding unit that names it.

The host limits are fixed:

- fuel is 5_000_000 instructions
- linear memory is 8 MiB
- a module is at most 1 MiB unless you raise `wasm_module_bytes:`
- `wasm_module_bytes:` cannot exceed 16 MiB

An omitted `wasm_id` selects module 0. Fuel exhaustion and the memory cap return `:resource_limit`. A module above the cap returns the same category. A panic or a corrupt unit returns `:corrupt`. These limits apply only after you opt in, and only when the native decoder is compiled.

This library does not fetch `lib_urls`. It does not generate Wasm, and the writer does not embed a module. If you would rather decode that unit in Elixir, register an `F3.Extension` and pass `extensions:` as described in [Decoders](08-decoders.md). An extension that matches does not fall through into the sandbox.
