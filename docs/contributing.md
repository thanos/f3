# Building from source

Elixir 1.20.2 and OTP 28. The default `mix test` does not compile Rust. Metadata tests and the user-guide examples that avoid `F3.read/2` run on that build.

```shell
mix deps.get
mix test
mix ci
```

`mix ci` is the required CI job: format, compile with warnings as errors, Credo, tests with coverage, and docs. It stops at the first failing step. The test step stops at the first failed test and requires 90% line coverage.

A git checkout compiles Rust only when `F3_BUILD_NATIVE=1`. Hex has not been published.

## Releases

Pushing a tag `vX.Y.Z` that matches `@version` in `mix.exs` runs `.github/workflows/precompile.yml`. That workflow builds the NIF and the `f3_write` helper and attaches the archives to the GitHub release:

- `aarch64-apple-darwin` on `macos-15`
- `x86_64-unknown-linux-gnu` on `ubuntu-latest`

The NIF archive is `libf3_native-vVERSION-nif-2.17-TARGET.so.tar.gz`. OTP 28 uses NIF version 2.17. The writer archive is `f3_write-vVERSION-TARGET.tar.gz`. `.github/workflows/publish.yml` then writes `checksum-Elixir.F3.Native.exs` and `checksum-f3_write.exs` and runs `mix hex.publish`. A local `mix hex.publish --dry-run` omits those files. The publish job writes them first, and the package list picks up whatever `checksum-*.exs` files are present. It sets `F3_SKIP_NATIVE_FETCH=1` so that publish packages the checksums without downloading the archives again. The repository secret `HEX_API_KEY` is required. Those checksum files are not in git. A Hex install downloads the archives for the two targets above. `F3_BUILD_NATIVE=1` still compiles from source, including for any other target.

```shell
F3_BUILD_NATIVE=1 mix compile
F3_BUILD_NATIVE=1 mix test --only native
```

The NIF build calls rustup's `nightly-2025-11-15` binaries even when asdf or Homebrew puts a stable `cargo` earlier on `PATH`. The writer is a separate `f3_write` binary. That build fetches pinned `fff-poc` at `bd92506447dc1333820cfe9a34ebbf497fe0219e` and compiles it with `nightly-2025-02-24`. The NIF decodes one CASCADE encoding unit on the dirty CPU scheduler and, only when Elixir asks, one Wasm module with Wasmtime 28. It does not link `fff-poc` and it does not install a global allocator. Mix recompiles `F3.Native` when the flag changes. The default `mix test` excludes the native tests and does not invoke `cargo`.

`scripts/bench.exs` times `F3.read/2` and `F3.stream/2` on the committed fixtures. It does not download data and it is not a CI gate. `mix test` excludes the `:minio` tag unless `F3_MINIO=1`.

Regenerate fixtures with `scripts/fixtures/generate.sh`. That script clones the pinned upstream commit, builds `fff-poc` with Rust `nightly-2025-02-24`, and rewrites `test/fixtures/`. It is not part of `mix test`.

The wire-format pin is in [upstream compatibility](upstream-compatibility.md). The component map is in [architecture](architecture.md). The test record is in `docs/test-reports/`.
