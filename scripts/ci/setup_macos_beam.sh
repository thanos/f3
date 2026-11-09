#!/bin/bash
# macOS runners download OTP through erlef/setup-beam from erlef/otp_builds
# release assets, and those assets return HTTP 504. Homebrew erlang@28 is
# an OTP 28 bottle (NIF 2.17). Elixir 1.20.2 comes from builds.hex.pm.
set -euo pipefail

export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1

brew install erlang@28
otp_bin="$(brew --prefix erlang@28)/bin"

elixir_root="${RUNNER_TEMP}/elixir-1.20.2"
mkdir -p "$elixir_root"
curl --retry 5 --retry-delay 2 -fsSL \
  -o "$elixir_root/elixir.zip" \
  https://builds.hex.pm/builds/elixir/v1.20.2-otp-28.zip
unzip -q "$elixir_root/elixir.zip" -d "$elixir_root"

echo "$otp_bin" >> "$GITHUB_PATH"
echo "$elixir_root/bin" >> "$GITHUB_PATH"
echo "${HOME}/.mix/escripts" >> "$GITHUB_PATH"

export PATH="${otp_bin}:${elixir_root}/bin:${HOME}/.mix/escripts:${PATH}"
mix local.hex --force
mix local.rebar --force
erl -eval 'io:format("otp ~s~n", [erlang:system_info(otp_release)]), halt().' -noshell
elixir --version
