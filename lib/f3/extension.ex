defmodule F3.Extension do
  @moduledoc """
  Elixir decoder registered for one footer encoding.

  This is this library's policy. An F3 file has no field that names an
  Elixir module. `decode/3` receives the encoded bytes, the footer fields
  that describe that unit, and the physical Arrow type.

  `metadata` is `%{encoding: atom, version: %{major, minor, patch}, wasm_id:
  non_neg_integer | nil, compression: atom}`. An error is returned to the
  caller. The reader does not fall through into Wasm.
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

  @callback decode(binary(), metadata(), atom()) ::
              {:ok, F3.Column.t()} | {:error, F3.Error.t()}
end
