# Times F3.read/2 and F3.stream/2 on the committed fixtures.
#
# Run from the repository root:
#
#     mix run scripts/bench.exs
#
# The script does not download data. A missing decoder is a timed result, not
# a failed run. Peak RSS is printed only when a host command reports it.
# A Parquet comparison runs only when `pyarrow` or `parquet-cli` is on PATH.

defmodule F3.BenchScript do
  @moduledoc false

  def run do
    IO.puts("command: mix run scripts/bench.exs")
    IO.puts("elixir: #{System.version()}")
    IO.puts("otp: #{System.otp_release()}")
    IO.puts("native_stamp: #{stamp()}")

    "test/fixtures"
    |> Path.join("*.f3")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.each(&measure/1)

    report_rss()
    report_parquet()
    IO.puts("---")
    IO.puts("batch_size: default")
    IO.puts("projection: all columns")
  end

  defp stamp do
    case File.read("native/f3_native/.f3_build_native") do
      {:ok, value} -> String.trim(value)
      {:error, _reason} -> "missing"
    end
  end

  defp measure(path) do
    {:ok, file} = F3.open(path)
    {read_us, read} = :timer.tc(fn -> F3.read(file) end)
    {stream_us, stream} = :timer.tc(fn -> take_stream(file) end)
    {:ok, _} = F3.close(file)

    IO.puts("---")
    IO.puts("fixture: #{path}")
    IO.puts("bytes: #{File.stat!(path).size}")
    IO.puts("read_us: #{read_us}")
    IO.puts("read: #{summarize(read)}")
    IO.puts("stream_us: #{stream_us}")
    IO.puts("stream: #{summarize(stream)}")
  end

  defp take_stream(file) do
    with {:ok, rows} <- F3.stream(file) do
      try do
        {:ok, Enum.take(rows, 10_000)}
      catch
        {:f3, %F3.Error{} = error} -> {:error, error}
      end
    end
  end

  defp summarize({:ok, batches}) when is_list(batches) do
    rows = Enum.reduce(batches, 0, fn batch, acc -> acc + batch.num_rows end)
    "ok batches=#{length(batches)} rows=#{rows}"
  end

  defp summarize({:error, %F3.Error{category: category}}) do
    "error category=#{category}"
  end

  defp report_rss do
    IO.puts("---")

    cond do
      peak = proc_peak() ->
        IO.puts("peak_rss_kb: #{peak}")

      rss = ps_rss() ->
        IO.puts("ps_rss_kb: #{rss}")

      true ->
        IO.puts("peak rss: skipped")
    end
  end

  defp proc_peak do
    case File.read("/proc/self/status") do
      {:ok, status} ->
        case Regex.run(~r/VmHWM:\s+(\d+)/, status) do
          [_, kb] -> kb
          _other -> nil
        end

      {:error, _reason} ->
        nil
    end
  end

  defp ps_rss do
    pid = to_string(System.pid())

    case System.cmd("ps", ["-o", "rss=", "-p", pid], stderr_to_stdout: true) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {kb, ""} -> Integer.to_string(kb)
          _other -> nil
        end

      {_output, _status} ->
        nil
    end
  end

  defp report_parquet do
    IO.puts("---")

    cond do
      System.find_executable("pyarrow") ->
        IO.puts(compare_parquet("pyarrow"))

      System.find_executable("parquet-cli") ->
        IO.puts(compare_parquet("parquet-cli"))

      true ->
        IO.puts("parquet comparison: skipped")
    end
  end

  defp compare_parquet(tool) do
    case System.cmd(tool, ["--version"], stderr_to_stdout: true) do
      {output, 0} ->
        "parquet comparison: #{tool} #{String.trim(output)} (no parquet fixture is committed)"

      {_output, status} ->
        "parquet comparison: #{tool} exited #{status}"
    end
  end
end

F3.BenchScript.run()
