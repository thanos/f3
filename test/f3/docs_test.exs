defmodule F3.DocsTest do
  use ExUnit.Case, async: false

  @modules [
    F3,
    F3.Format,
    F3.Error,
    F3.File,
    F3.Batch,
    F3.Schema,
    F3.Column,
    F3.Checksum,
    F3.Postscript,
    F3.Footer,
    F3.Metadata,
    F3.Inspection,
    F3.Reader,
    F3.Writer,
    F3.Native,
    F3.Wasm,
    F3.Decoder,
    F3.Decoder.Native,
    F3.Extension,
    F3.Registry,
    F3.Dispatch,
    F3.Logical,
    F3.RowGroup,
    F3.FlatBuffer,
    F3.IO.Source,
    F3.IO.Memory,
    F3.IO.Local,
    F3.IO.HTTP,
    F3.IO.FileSystem,
    F3.IO.FileSystem.OS,
    Mix.Tasks.F3.Inspect
  ]

  Enum.each(@modules, fn module ->
    doctest module
  end)

  test "examples livebook cells run" do
    path = Path.expand("../../docs/examples.livemd", __DIR__)
    markdown = File.read!(path)

    cells =
      Regex.scan(~r/```elixir\n(.*?)```/s, markdown, capture: :all_but_first)
      |> Enum.map(&hd/1)

    assert length(cells) >= 8

    Enum.each(cells, fn cell ->
      Code.eval_string(cell)
    end)
  end
end
