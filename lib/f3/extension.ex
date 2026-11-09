defmodule F3.Extension do
  @moduledoc """
  Elixir decoder registered for one footer encoding.

  This is this library's policy. An F3 file has no field that names an
  Elixir module. `decode/3` receives the encoded bytes, the footer fields
  that describe that unit, and the physical Arrow type.

  `metadata` is `%{encoding: atom, version: %{major, minor, patch}, wasm_id:
  non_neg_integer | nil, compression: atom}`. An error is returned to the
  caller. The reader does not fall through into Wasm.

  ## Examples

  A counter extension ignores the unit bytes and returns one `int64`:

      defmodule TradeCount do
        @behaviour F3.Extension

        @impl true
        def decode(_bytes, _metadata, :i64) do
          F3.Column.from_native(:i64, 1, <<9::little-64>>, nil)
        end

        def decode(_bytes, _metadata, _type) do
          {:error, F3.Error.unsupported_encoding(:decode, "only int64")}
        end
      end
  """

  @typedoc """
  Footer fields for one encoding unit.

  `encoding` is `:cascade`, `:custom_wasm`, or an unknown integer.
  `version` is `%{major, minor, patch}`. `wasm_id` is the module index, or
  `nil` when the unit has none. `compression` is `:uncompressed`, `:zstd`,
  `:lz4`, or an unknown integer.
  """
  @type metadata :: %{
          encoding: F3.RowGroup.encoding(),
          version: %{
            major: non_neg_integer(),
            minor: non_neg_integer(),
            patch: non_neg_integer()
          },
          wasm_id: non_neg_integer() | nil,
          compression: F3.RowGroup.compression()
        }

  @doc """
  Decodes one unit for a registered encoding.

  `bytes` is the unit payload. `metadata` is the footer description above.
  `type` is the physical kind. Return `{:ok, column}` or
  `{:error, %F3.Error{}}`. Do not raise for a type the module refuses.
  """
  @callback decode(binary(), metadata(), atom()) ::
              {:ok, F3.Column.t()} | {:error, F3.Error.t()}
end
