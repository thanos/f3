# Fixture generator

`src/main.rs` is the program that calls upstream `FileWriter`. `scripts/fixtures/generate.sh` copies it to `tmp/upstream-f3/fff-poc/src/bin/f3_fixture_gen.rs` and builds that binary with `cargo build --locked` inside the pinned checkout.

The binary uses the library name `fff_poc`. It is not a freestanding crate. Resolving `fff-poc` outside the upstream `Cargo.lock` pulls crate versions that do not compile on `nightly-2025-02-24`.
