defmodule F3.Decoder do
  @moduledoc """
  Decodes one CASCADE encoding unit into an owned `F3.Column`.

  The default implementation is `F3.Decoder.Native`. Tests replace it by
  setting `Application.put_env(:f3, :decoder, module)`. The module must
  implement this behaviour. `F3.read/2` uses that module for every unit
  and does not call it when the native build is absent.

  ## Examples

  A test double returns one owned column and does not touch a file:

      defmodule SampleDecoder do
        @behaviour F3.Decoder

        @impl true
        def decode(_bytes, :uncompressed, :i64) do
          F3.Column.from_native(:i64, 1, <<1::little-64>>, nil)
        end

        def decode(_bytes, _compression, _type) do
          {:error, F3.Error.unsupported_encoding(:decode, "unsupported unit")}
        end
      end

  `decode/3` receives the unit bytes, the compression atom, and the
  physical type atom. It returns `{:ok, column}` or `{:error, %F3.Error{}}`.
  It should not raise for a unit it refuses.
  """

  @doc """
  Decodes one CASCADE unit.

  `bytes` is the unit payload. `compression` is `:uncompressed`, `:zstd`,
  or `:lz4`. `type` is the physical kind, such as `:i64`. The return is an
  owned column or an error. A refusal does not raise.
  """
  @callback decode(binary(), atom(), atom()) :: {:ok, F3.Column.t()} | {:error, F3.Error.t()}
end
