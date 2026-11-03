#!/usr/bin/env bash
# Write test/fixtures/golden/*.json from the pinned upstream FlatBuffers reader.
# This is a regeneration step. mix test compares the committed JSON and does
# not compile upstream.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SHA="bd92506447dc1333820cfe9a34ebbf497fe0219e"
DEST="${ROOT}/tmp/upstream-f3"
OUT="${ROOT}/test/fixtures/golden"
RUSTUP="${HOME}/.cargo/bin/rustup"
TOOLCHAIN="nightly-2025-02-24"

if [[ ! -d "${DEST}/.git" ]]; then
  echo "missing ${DEST}; run scripts/fixtures/generate.sh first" >&2
  exit 1
fi

current="$(git -C "${DEST}" rev-parse HEAD)"
if [[ "${current}" != "${SHA}" ]]; then
  echo "upstream checkout is ${current}, expected ${SHA}" >&2
  exit 1
fi

TC_BIN="$(dirname "$("${RUSTUP}" which --toolchain "${TOOLCHAIN}" rustc)")"
export PATH="${TC_BIN}:$(printf '%s' "${PATH}" | tr ':' '\n' | grep -v '/\.asdf/shims' | paste -sd ':' -)"
export RUSTC="${TC_BIN}/rustc"
export CARGO="${TC_BIN}/cargo"
hash -r

mkdir -p "${DEST}/fff-poc/examples" "${OUT}"
cp "${ROOT}/scripts/fixtures/metadata_dump.rs" "${DEST}/fff-poc/examples/metadata_dump.rs"

files=()
for path in "${ROOT}"/test/fixtures/*.f3; do
  files+=("${path}")
done

(
  cd "${DEST}"
  "${CARGO}" run --locked --release -p fff-poc --example metadata_dump -- "${OUT}" "${files[@]}"
)

echo "wrote ${OUT}"
