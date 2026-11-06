defmodule F3.Native do
  @moduledoc """
  Optional native decoder.

  The NIF is compiled only when `F3_BUILD_NATIVE=1` is set in the environment
  at compile time and the `rustler` dependency is available. `info/0` reports
  the crate name and version. `decode_encunit/3` decodes one CASCADE encoding
  unit on the dirty CPU scheduler. It does not open files, decode FlatBuffers,
  or run WebAssembly. The crate does not link `fff-poc` and does not install
  a global allocator. Wasmtime 28 is in the same crate. It runs only when
  `decode_wasm/5` is called, which `F3.read/2` does only for `wasm: :sandbox`.

  `available?/0` is false in the default build, which does not invoke `cargo`.
  Mix recompiles this module when `F3_BUILD_NATIVE` changes. `mix test` and
  `mix compile` both pick up the current value.
  """

  @external_resource Path.expand("../../native/f3_native/.f3_build_native", __DIR__)
  @external_resource Path.expand("../../native/f3_write/src/main.rs", __DIR__)
  @build_native System.get_env("F3_BUILD_NATIVE") == "1"

  if @build_native do
    unless Code.ensure_loaded?(Rustler) do
      raise "F3_BUILD_NATIVE=1 requires the rustler dependency to be present"
    end

    # asdf and Homebrew both install a stable `cargo` that ignores
    # rust-toolchain.toml. `rustup run` does not put its toolchain ahead of
    # those shims, so Cargo would still spawn the stable `rustc`.
    rustup =
      System.find_executable("rustup") || Path.join(System.user_home!(), ".cargo/bin/rustup")

    unless File.regular?(rustup) do
      raise "F3_BUILD_NATIVE=1 requires rustup and the nightly-2025-11-15 toolchain"
    end

    {rustc_out, rustc_status} =
      System.cmd(rustup, ["which", "--toolchain", "nightly-2025-11-15", "rustc"])

    if rustc_status != 0 do
      raise "install the pinned toolchain with: rustup toolchain install nightly-2025-11-15\n#{rustc_out}"
    end

    rustc = String.trim(rustc_out)
    nightly_bin = Path.dirname(rustc)

    use Rustler,
      otp_app: :f3,
      crate: "f3_native",
      cargo: {:bin, Path.join(nightly_bin, "cargo")},
      env: [
        {"RUSTC", rustc},
        {"PATH", nightly_bin <> ":" <> System.get_env("PATH", "")}
      ]
  end

  if @build_native do
    @doc """
    Whether this VM loaded the native scaffold.
    """
    @spec available?() :: boolean()
    def available?, do: match?({:ok, {_crate, _version}}, info())
  else
    @doc """
    Whether this VM loaded the native scaffold.
    """
    @spec available?() :: boolean()
    def available?, do: false
  end

  if @build_native do
    @doc """
    Returns `{:ok, {crate_name, version}}` when the NIF is loaded.
    """
    @spec info() :: {:ok, {String.t(), String.t()}} | {:error, :native_unavailable}
    def info do
      case load_info() do
        {:ok, {crate, version} = pair} when is_binary(crate) and is_binary(version) ->
          {:ok, pair}

        _other ->
          {:error, :native_unavailable}
      end
    end

    @doc false
    @spec nif_info() :: {String.t(), String.t()}
    def nif_info, do: :erlang.nif_error(:nif_not_loaded)

    @doc """
    Decodes one encoding unit. Returns `{:ok, {kind, rows, values, validity}}`
    or `{:error, message}`. Panics become `{:error, "panic"}`.
    """
    @spec decode_encunit(binary(), atom(), atom()) ::
            {:ok, {atom(), non_neg_integer(), term(), binary() | nil}}
            | {:error, String.t()}
    def decode_encunit(_bytes, _compression, _type), do: :erlang.nif_error(:nif_not_loaded)

    defp load_info do
      {:ok, nif_info()}
    rescue
      ErlangError -> {:error, :native_unavailable}
    end

    @doc false
    @spec require_decoder(atom()) :: {:ok, module()} | {:error, F3.Error.t()}
    def require_decoder(operation) do
      if available?() do
        {:ok, F3.Decoder.Native}
      else
        {:error, F3.Error.native_unavailable(operation)}
      end
    end

    @doc false
    @spec apply_decode(binary(), atom(), atom()) :: {:ok, F3.Column.t()} | {:error, F3.Error.t()}
    def apply_decode(bytes, compression, type) do
      case decode_encunit(bytes, compression, type) do
        {:ok, native} ->
          column_from(native)

        {:error, message} ->
          {:error, wasm_error(message)}

        _other ->
          {:error, F3.Error.corrupt(:decode, "native decoder returned an unexpected term")}
      end
    end

    @doc false
    @spec decode_wasm(binary(), binary(), atom(), atom(), non_neg_integer()) ::
            {:ok, {atom(), non_neg_integer(), term(), binary() | nil}} | {:error, String.t()}
    def decode_wasm(_module, _bytes, _compression, _type, _rows),
      do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec clear_wasm_cache() :: :ok
    def clear_wasm_cache, do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec invalidate_wasm(binary()) :: :ok
    def invalidate_wasm(_bytes), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec wasm_sample(String.t()) :: {:ok, binary()} | {:error, String.t()}
    def wasm_sample(_name), do: :erlang.nif_error(:nif_not_loaded)

    @doc false
    @spec apply_wasm(binary(), binary(), atom(), atom(), non_neg_integer(), atom()) ::
            {:ok, F3.Column.t()} | {:error, F3.Error.t()}
    def apply_wasm(module, bytes, compression, type, rows, operation) do
      case decode_wasm(module, bytes, compression, type, rows) do
        {:ok, native} -> column_from(native)
        {:error, message} -> {:error, wasm_error(message, operation)}
        _other -> {:error, F3.Error.corrupt(operation, "wasm host returned an unexpected term")}
      end
    end

    defp column_from({kind, rows, values, validity}) do
      F3.Column.from_native(kind, rows, values, validity)
    end

    defp wasm_error(message, operation \\ :decode) do
      case message do
        "panic" -> F3.Error.corrupt(operation, "encunit decode panicked")
        "fuel exhausted" -> F3.Error.resource_limit(operation, "wasm fuel is exhausted")
        "memory limit" -> F3.Error.resource_limit(operation, "wasm memory limit")
        "module bytes" -> F3.Error.resource_limit(operation, "wasm module is above 16 MiB")
        other -> wasm_error_rest(other, operation)
      end
    end

    defp wasm_error_rest(message, operation) do
      case message do
        "unknown compression" ->
          F3.Error.unsupported_encoding(operation, "unknown compression")

        "unknown arrow type" ->
          F3.Error.unsupported_encoding(operation, "unknown arrow type")

        "nested wasm" ->
          F3.Error.unsupported_encoding(operation, "nested wasm output is not decoded")

        message when is_binary(message) ->
          F3.Error.corrupt(operation, message)

        _other ->
          F3.Error.corrupt(operation, "native decoder returned an unexpected term")
      end
    end
  else
    @doc """
    Returns `{:ok, {crate_name, version}}` when the NIF is loaded.
    """
    @spec info() :: {:ok, {String.t(), String.t()}} | {:error, :native_unavailable}
    def info, do: {:error, :native_unavailable}

    @doc false
    @spec require_decoder(atom()) :: {:error, F3.Error.t()}
    def require_decoder(operation), do: {:error, F3.Error.native_unavailable(operation)}

    @doc false
    @spec apply_decode(binary(), atom(), atom()) :: {:error, F3.Error.t()}
    def apply_decode(_bytes, _compression, _type) do
      {:error, F3.Error.native_unavailable(:decode)}
    end

    @doc false
    @spec apply_wasm(binary(), binary(), atom(), atom(), non_neg_integer(), atom()) ::
            {:error, F3.Error.t()}
    def apply_wasm(_module, _bytes, _compression, _type, _rows, operation) do
      {:error, F3.Error.native_unavailable(operation)}
    end

    @doc false
    @spec clear_wasm_cache() :: :ok
    def clear_wasm_cache, do: :ok

    @doc false
    @spec invalidate_wasm(binary()) :: :ok
    def invalidate_wasm(_bytes), do: :ok

    @doc false
    @spec wasm_sample(String.t()) :: {:error, :native_unavailable}
    def wasm_sample(_name), do: {:error, :native_unavailable}
  end

  if not @build_native do
    @doc """
    Decodes one encoding unit when the NIF was compiled.
    """
    @spec decode_encunit(binary(), atom(), atom()) :: {:error, :native_unavailable}
    def decode_encunit(_bytes, _compression, _type), do: {:error, :native_unavailable}

    @doc false
    @spec decode_wasm(binary(), binary(), atom(), atom(), non_neg_integer()) ::
            {:error, :native_unavailable}
    def decode_wasm(_module, _bytes, _compression, _type, _rows),
      do: {:error, :native_unavailable}
  end
end
