defmodule F3.Native do
  @moduledoc """
  Optional stable-Rust scaffold.

  The NIF is compiled only when `F3_BUILD_NATIVE=1` is set in the environment
  at compile time and the `rustler` dependency is available. The loaded
  function reports the crate name and version. It does not open files, decode
  FlatBuffers, or run WebAssembly.

  `available?/0` is false in the default build, which does not invoke `cargo`.
  Mix reads `F3_BUILD_NATIVE` while compiling this module. After changing the
  flag, run `mix compile --force` so the previously compiled beam is replaced.
  """

  @build_native System.get_env("F3_BUILD_NATIVE") == "1"

  if @build_native do
    unless Code.ensure_loaded?(Rustler) do
      raise "F3_BUILD_NATIVE=1 requires the rustler dependency to be present"
    end

    use Rustler, otp_app: :f3, crate: "f3_native"
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

    defp load_info do
      {:ok, nif_info()}
    rescue
      ErlangError -> {:error, :native_unavailable}
    end
  else
    @doc """
    Returns `{:ok, {crate_name, version}}` when the NIF is loaded.
    """
    @spec info() :: {:ok, {String.t(), String.t()}} | {:error, :native_unavailable}
    def info, do: {:error, :native_unavailable}
  end
end
