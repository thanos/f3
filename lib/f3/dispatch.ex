defmodule F3.Dispatch do
  @moduledoc """
  Chooses a decoder for one encoding unit.

  A CASCADE unit whose footer version is compatible with native `0.21.0`
  uses the Vortex NIF. Otherwise a registered `F3.Extension` wins. Otherwise
  sandboxed Wasm runs when the read passed `wasm: :sandbox`. Anything else
  is `:unsupported_encoding`. An extension route does not fall through.
  """

  alias F3.Error

  @cascade %{major: 0, minor: 21, patch: 0}

  @doc """
  Native CASCADE version this build decodes without Wasm.

  ## Examples

      iex> F3.Dispatch.cascade_version()
      %{major: 0, minor: 21, patch: 0}
  """
  @spec cascade_version() :: %{major: 0, minor: 21, patch: 0}
  def cascade_version, do: @cascade

  @doc """
  `{:ok, :native | :wasm | {:extension, module}}` or an error.

  `plan` needs `:versions`, `:wasm`, `:extensions`, and `:operation`.
  Upstream runs Wasm for CASCADE when the file version is newer and the
  reader major is 0 or the majors differ. Native `0.21.0` has major 0, so
  any newer CASCADE version takes the Wasm path. An equal or older version
  stays on the Vortex NIF.   The committed fixtures are `0.21.0`.

  A missing version is `:corrupt`. This does not raise for a map plan.

  ## Examples

      iex> unit = %{encoding: :cascade, compression: :uncompressed, wasm_id: nil}
      iex> version = %{major: 0, minor: 21, patch: 0}
      iex> plan = %{versions: [%{encoding: :cascade, version: version}], wasm: :off, operation: :read}
      iex> F3.Dispatch.choose(unit, plan)
      {:ok, :native}
      iex> {:error, error} = F3.Dispatch.choose(unit, %{versions: [], operation: :read})
      iex> error.category
      :corrupt
  """
  @spec choose(map(), map()) ::
          {:ok, :native | :wasm | {:extension, module()}} | {:error, Error.t()}
  def choose(unit, plan) when is_map(unit) and is_map(plan) do
    operation = Map.get(plan, :operation, :read)

    case version(plan, unit.encoding) do
      :missing ->
        {:error, Error.corrupt(operation, "encoding version not found")}

      version ->
        route(unit, version, plan, operation)
    end
  end

  @doc """
  Whether this CASCADE version stays on the Vortex NIF.

  `file` is `%{major, minor, patch}`. An equal or older version stays native.
  A newer version with major 0 takes Wasm.

  ## Examples

      iex> F3.Dispatch.cascade_native?(%{major: 0, minor: 21, patch: 0})
      true
      iex> F3.Dispatch.cascade_native?(%{major: 0, minor: 22, patch: 0})
      false
  """
  @spec cascade_native?(map()) :: boolean()
  def cascade_native?(file) when is_map(file) do
    case compare(@cascade, file) do
      :lt -> @cascade.major == file.major and @cascade.major != 0
      _other -> true
    end
  end

  defp route(%{encoding: :cascade} = unit, version, plan, operation) do
    if cascade_native?(version) do
      compression_ok(unit, operation, :native)
    else
      after_native(unit, version, plan, operation)
    end
  end

  defp route(unit, version, plan, operation) do
    after_native(unit, version, plan, operation)
  end

  defp after_native(unit, version, plan, operation) do
    metadata = %{
      encoding: unit.encoding,
      version: version,
      wasm_id: Map.get(unit, :wasm_id),
      compression: unit.compression
    }

    case F3.Registry.lookup(Map.get(plan, :extensions), metadata) do
      {:ok, module} ->
        {:ok, {:extension, module}}

      :error ->
        if Map.get(plan, :wasm) == :sandbox do
          compression_ok(unit, operation, :wasm)
        else
          {:error, Error.unsupported_encoding(operation, refusal(unit))}
        end
    end
  end

  defp compression_ok(%{compression: compression}, _operation, route)
       when compression in [:uncompressed, :zstd, :lz4], do: {:ok, route}

  defp compression_ok(%{encoding: encoding, compression: compression}, operation, _route) do
    {:error,
     Error.unsupported_encoding(
       operation,
       "encoding #{inspect(encoding)} compression #{inspect(compression)}"
     )}
  end

  defp version(plan, encoding) do
    case Enum.find(Map.get(plan, :versions, []), &(&1.encoding == encoding)) do
      %{version: version} -> version
      nil -> :missing
    end
  end

  defp refusal(%{encoding: :custom_wasm}) do
    "CUSTOM_WASM is not executed"
  end

  defp refusal(%{encoding: encoding, compression: compression}) do
    "encoding #{inspect(encoding)} compression #{inspect(compression)}"
  end

  defp compare(left, right) do
    cond do
      left.major != right.major -> order(left.major, right.major)
      left.minor != right.minor -> order(left.minor, right.minor)
      left.patch != right.patch -> order(left.patch, right.patch)
      true -> :eq
    end
  end

  defp order(left, right) when left < right, do: :lt
  defp order(left, right) when left > right, do: :gt
end
