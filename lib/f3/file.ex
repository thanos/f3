defmodule F3.File do
  @moduledoc """
  Open file handle.

  The handle owns a `F3.IO.Source`. `F3.open/2` does not check magic or
  decode metadata. `F3.close/1` releases the source. Closing a closed
  handle succeeds and returns the same closed handle.

  A memory handle keeps the source binary until close. An HTTP handle's
  origin is the url without userinfo. `Inspect` prints the origin and
  closed flag, not bytes or request headers.
  """

  @enforce_keys [:source_module, :source_state, :origin]
  defstruct [:source_module, :source_state, :origin, closed: false]

  @type origin :: Path.t() | :memory

  @type t :: %__MODULE__{
          source_module: module(),
          source_state: F3.IO.Source.state(),
          origin: origin(),
          closed: boolean()
        }

  defimpl Inspect do
    def inspect(%F3.File{origin: origin, closed: closed, source_module: source}, _opts) do
      "#F3.File<origin: #{inspect(origin)}, source: #{inspect(source)}, closed: #{closed}>"
    end
  end
end
