defmodule F3.TaskTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  test "mix f3.inspect prints json and refuses a bad invocation" do
    output =
      capture_io(fn ->
        Mix.Tasks.F3.Inspect.run(["test/fixtures/small.f3", "--json"])
      end)

    assert {:ok, decoded} = JSON.decode(output)

    assert Enum.map(decoded["schema"], & &1["name"]) == ["trade_id", "symbol", "price"]

    assert_raise Mix.Error, ~r/usage: mix f3.inspect/, fn ->
      Mix.Tasks.F3.Inspect.run([])
    end

    assert_raise Mix.Error, ~r/unknown arguments/, fn ->
      Mix.Tasks.F3.Inspect.run(["test/fixtures/small.f3", "--nope"])
    end

    assert_raise Mix.Error, ~r/metadata size exceeds/, fn ->
      Mix.Tasks.F3.Inspect.run(["test/fixtures/small.f3", "--max-metadata-bytes", "1"])
    end

    path = Path.join(System.tmp_dir!(), "f3-task-#{System.unique_integer([:positive])}.f3")
    File.write!(path, "short")
    on_exit(fn -> File.rm(path) end)

    assert_raise Mix.Error, ~r/shorter than the 32 byte postscript/, fn ->
      Mix.Tasks.F3.Inspect.run([path])
    end
  end
end
