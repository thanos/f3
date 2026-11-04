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
    assert output =~ "inspect:"
    assert output =~ "schema: trade_id int64, symbol utf8, price float64"
    assert output =~ "column 0 trade_id"
    assert output =~ "schema: (none)"
  end

  test "tutorial 3 example opens the fixture and refuses a row read" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_03.exs")
      end)

    assert output =~ "command: mix run examples/tutorial_03.exs"
    assert output =~ "trade_id int64"
    assert output =~ "symbol utf8"
    assert output =~ "price float64"
    assert output =~ "row_groups: 1"
    assert output =~ "rows: 3"
    assert output =~ "read: not implemented"
    assert output =~ "after close: closed"
  end

  test "mix f3.inspect prints the compact summary" do
    output =
      capture_io(fn ->
        Mix.Tasks.F3.Inspect.run(["test/fixtures/small.f3"])
      end)

    assert output =~ "schema: trade_id int64, symbol utf8, price float64"
    refute output =~ "chunk offset"
  end
end
