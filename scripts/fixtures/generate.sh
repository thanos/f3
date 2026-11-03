#!/usr/bin/env bash
# Regenerate test/fixtures/*.f3 with the pinned upstream F3 writer.
# Requires git, cmake, a C toolchain, ruby, and rustup.
# The Elixir package does not need this script to compile or to run tests.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHA="bd92506447dc1333820cfe9a34ebbf497fe0219e"
DEST="${ROOT}/tmp/upstream-f3"
OUT="${ROOT}/test/fixtures"
RUSTUP="${HOME}/.cargo/bin/rustup"
TOOLCHAIN="nightly-2025-02-24"
WASM_LOG="${ROOT}/tmp/wasm-build.log"

if [[ ! -x "${RUSTUP}" ]]; then
  echo "rustup is required at ${RUSTUP}" >&2
  exit 1
fi

mkdir -p "${ROOT}/tmp" "${OUT}"

if [[ ! -d "${DEST}/.git" ]]; then
  git init "${DEST}"
  git -C "${DEST}" remote add origin https://github.com/future-file-format/F3.git
fi

current="$(git -C "${DEST}" rev-parse HEAD 2>/dev/null || true)"
if [[ "${current}" != "${SHA}" ]]; then
  git -C "${DEST}" fetch --depth 1 origin "${SHA}"
  git -C "${DEST}" checkout --detach FETCH_HEAD
fi

git -C "${DEST}" submodule update --init --recursive

"${RUSTUP}" toolchain install "${TOOLCHAIN}" --profile minimal
"${RUSTUP}" target add wasm32-wasip1 --toolchain "${TOOLCHAIN}"

# asdf shims sit ahead of rustup and then fail inside the cargo registry,
# where no .tool-versions selects Rust. Call the nightly binaries directly.
TC_BIN="$(dirname "$("${RUSTUP}" which --toolchain "${TOOLCHAIN}" rustc)")"
export PATH="${TC_BIN}:$(printf '%s' "${PATH}" | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd ':' -)"
export RUSTC="${TC_BIN}/rustc"
export CARGO="${TC_BIN}/cargo"
hash -r
echo "using $("${RUSTC}" -vV | head -n 1)"

# Compile as a bin of the fff-poc package so `cargo build --locked` uses
# upstream's Cargo.lock. A freestanding generator resolves crates this
# nightly cannot compile. The bin links the library as `fff_poc`, not `crate`.
mkdir -p "${DEST}/fff-poc/src/bin"
cp "${ROOT}/scripts/fixtures/generator/src/main.rs" \
  "${DEST}/fff-poc/src/bin/f3_fixture_gen.rs"

echo "building fixture generator with upstream Cargo.lock"
(
  cd "${DEST}"
  "${CARGO}" build --locked --release -p fff-poc --bin f3_fixture_gen
)

set +e
echo "building upstream built-in wasm decoder (optional)"
(
  cd "${DEST}"
  "${CARGO}" build --locked -p fff-ude-example-fff \
    --target wasm32-wasip1 \
    --profile opt-size-lvl3 \
    >"${WASM_LOG}" 2>&1
)
wasm_status=$?
set -e

if [[ "${wasm_status}" -ne 0 ]]; then
  echo "wasm build failed; see ${WASM_LOG}" >&2
fi

find "${OUT}" -name '*.f3' -delete
rm -f "${OUT}/intent.json" "${OUT}/manifest.json"

"${DEST}/target/release/f3_fixture_gen" \
  --upstream "${DEST}" \
  --out "${OUT}" \
  --wasm-log "${WASM_LOG}"

ruby -rjson -rdigest -e '
  out = ARGV.fetch(0)
  intent_path = File.join(out, "intent.json")
  intent = JSON.parse(File.read(intent_path))
  intent["fixtures"].each do |fixture|
    path = File.join(out, fixture.fetch("name"))
    bytes = File.binread(path)
    raise "#{fixture["name"]} is shorter than 32 bytes" if bytes.bytesize < 32
    raise "#{fixture["name"]} does not end with F3" unless bytes.end_with?("F3")
    fixture["bytes"] = bytes.bytesize
    fixture["sha256"] = Digest::SHA256.hexdigest(bytes)
  end
  intent["manifest_generated_at"] = Time.now.utc.strftime("%Y-%m-%dT%H:%M:%SZ")
  File.write(File.join(out, "manifest.json"), JSON.pretty_generate(intent) + "\n")
  File.delete(intent_path)
' "${OUT}"

echo "wrote ${OUT}/manifest.json"
