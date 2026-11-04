defmodule F3.Decoder do
  @moduledoc """
  Decodes one CASCADE encoding unit into an owned `F3.Column`.

  The default implementation is `F3.Decoder.Native`. Tests replace it by
  setting `Application.put_env(:f3, :decoder, module)`. The module must
  implement this behaviour. `F3.read/2` uses that module for every unit
  and does not call it when the native build is absent.
  """

  @callback decode(binary(), atom(), atom()) :: {:ok, F3.Column.t()} | {:error, F3.Error.t()}
end
