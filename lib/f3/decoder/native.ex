defmodule F3.Decoder.Native do
  @moduledoc """
  Calls the dirty-CPU NIF for one encoding unit.

  The NIF is loaded only when `F3_BUILD_NATIVE=1` was set at compile time.
  Otherwise `decode/3` returns `:native_unavailable` and does not read a file.
  A panic inside the NIF comes back as `{:error, %F3.Error{category: :corrupt}}`.
  """

  @behaviour F3.Decoder

  @doc """
  Decodes `bytes` after applying `compression`, as `type`.
  """
  @spec decode(binary(), atom(), atom()) :: {:ok, F3.Column.t()} | {:error, F3.Error.t()}
  def decode(bytes, compression, type)
      when is_binary(bytes) and is_atom(compression) and is_atom(type) do
    F3.Native.apply_decode(bytes, compression, type)
  end
end
