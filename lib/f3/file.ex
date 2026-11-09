defmodule F3.File do
  @moduledoc """
  Open file handle.

  The handle owns a `F3.IO.Source`. `F3.open/2` does not check magic or
  decode metadata. `F3.close/1` releases the source. Closing a closed
  handle succeeds and returns the same closed handle.

  A memory handle keeps the source binary until close. An HTTP handle's
  origin is the url without userinfo. `Inspect` prints the origin, the
  source module, and the closed flag. It does not print bytes or request
  headers.

  `source_module` is the `F3.IO.Source` implementation. `source_state` is
  that module's handle. `origin` is the path, `:memory`, or the display
  URL. `closed` is false until `F3.close/1`.

  ## Examples

      iex> {:ok, file} = F3.open("test/fixtures/small.f3")
      iex> inspect(file)
      ~s(#F3.File<origin: "test/fixtures/small.f3", source: F3.IO.Local, closed: false>)
      iex> {:ok, closed} = F3.close(file)
      iex> closed.closed
      true
  """

  @enforce_keys [:source_module, :source_state, :origin]
  defstruct [:source_module, :source_state, :origin, closed: false]

  @typedoc "Path, `:memory`, or the HTTP url with userinfo removed."
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
