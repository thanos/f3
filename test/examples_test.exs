defmodule F3.ExamplesTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "tutorial 1 example runs" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_01.exs")
      end)

    assert output =~ "experimental"
    assert output =~ "research prototype"
    assert output =~ "not implemented"
    assert output =~ "Compatible with 0.1: true"
  end

  test "tutorial 2 example prints the committed small fixture tail" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_02.exs")
      end)

    assert output =~ "command: mix run examples/tutorial_02.exs"
    assert output =~ "fixture: test/fixtures/small.f3"
    assert output =~ "magic: F3"
    assert output =~ "major_version: 0"
    assert output =~ "minor_version: 1"
    assert output =~ "tail_hex:"
  end
end
