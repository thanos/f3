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
    assert output =~ "Reading rows: implemented when the native decoder is compiled"
    assert output =~ "Writing rows: implemented when the native writer is compiled"
    assert output =~ "Wasm: off unless wasm: :sandbox"
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
    assert output =~ "read: native decoder is not loaded"
    assert output =~ "write: native writer is not loaded"
    assert output =~ "after close: closed"
  end

  test "tutorial 4 example reports a missing decoder or a projected batch" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_04.exs")
      end)

    assert output =~ "command: mix run examples/tutorial_04.exs"
    assert output =~ "stream: native decoder is not loaded"
  end

  test "tutorial 5 example reports that the writer is not loaded" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_05.exs")
      end)

    assert output =~ "command: mix run examples/tutorial_05.exs"
    assert output =~ "write: native writer is not loaded"
  end

  test "tutorial 6 keeps wasm off unless the native sandbox is compiled" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_06.exs")
      end)

    assert output =~ "command: mix run examples/tutorial_06.exs"
    assert output =~ "wasm: off"
    assert output =~ "extension rows:"
    assert output =~ "trade_id"
    assert output =~ "wasm: sandbox needs the native decoder"
  end

  test "tutorial 7 compares jobs and prints the small schema" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_07.exs")
      end)

    assert output =~ "command: mix run examples/tutorial_07.exs"
    assert output =~ "comparison: jobs, not speeds"
    assert output =~ "schema: trade_id int64, symbol utf8, price float64"
    refute output =~ "read_us"
  end

  test "tutorial 8 prints the postscript cap and the wasm default" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_08.exs")
      end)

    assert output =~ "command: mix run examples/tutorial_08.exs"
    assert output =~ "max_metadata_bytes: 16777216"
    assert output =~ "nif: dirty CPU when F3_BUILD_NATIVE=1"
    assert output =~ "wasm: off unless wasm: :sandbox"
    assert output =~ "read: native_unavailable"
    assert output =~ "lib_urls unread"
  end

  test "tutorial 9 quotes the recorded bench run" do
    output =
      capture_io(fn ->
        Code.eval_file("examples/tutorial_09.exs")
      end)

    assert output =~ "command: mix run examples/tutorial_09.exs"
    assert output =~ "recorded native_stamp: 0"
    assert output =~ "recorded small.f3 read_us: 81"
    assert output =~ "recorded maximum resident set size: 109854720"
    assert output =~ "parquet comparison: skipped"
    assert output =~ "hex: not published"
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
