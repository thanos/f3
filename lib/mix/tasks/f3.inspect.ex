defmodule Mix.Tasks.F3.Inspect do
  @moduledoc """
  Prints metadata for one F3 file.

      mix f3.inspect test/fixtures/small.f3
      mix f3.inspect test/fixtures/small.f3 --detail
      mix f3.inspect test/fixtures/small.f3 --json

  The output is `F3.inspect/2`. It does not read row data.

  `--detail` adds row groups. `--json` prints the metadata map.
  `--max-metadata-bytes N` overrides the footer cap. No path, or an unknown
  flag, raises `Mix.Error`. A missing file raises `Mix.Error` with the
  `F3.Error` message.
  """

  use Mix.Task

  @shortdoc "Print F3 postscript and footer metadata"

  @doc """
  Runs the task.

  `args` is the command-line list. A successful run prints the inspection
  and returns `:ok`. An empty list raises `Mix.Error`.

  ## Examples

      iex> Mix.Tasks.F3.Inspect.run([])
      ** (Mix.Error) usage: mix f3.inspect FILE [--detail] [--json] [--max-metadata-bytes N]
  """
  @impl Mix.Task
  def run(args) do
    Mix.Task.run("app.start")

    {opts, paths, invalid} =
      OptionParser.parse(args,
        strict: [detail: :boolean, json: :boolean, max_metadata_bytes: :integer]
      )

    cond do
      invalid != [] ->
        Mix.raise("unknown arguments: #{inspect(invalid)}")

      paths == [] ->
        Mix.raise("usage: mix f3.inspect FILE [--detail] [--json] [--max-metadata-bytes N]")

      true ->
        Enum.each(paths, &inspect_path(&1, opts))
    end
  end

  defp inspect_path(path, opts) do
    inspect_opts =
      []
      |> maybe(:detail, Keyword.get(opts, :detail, false))
      |> maybe(:format, if(Keyword.get(opts, :json, false), do: :json, else: :text))
      |> maybe(:max_metadata_bytes, Keyword.get(opts, :max_metadata_bytes))

    with {:ok, file} <- F3.open(path),
         {:ok, text} <- F3.inspect(file, inspect_opts) do
      Mix.shell().info(text)
      F3.close(file)
    else
      {:error, %F3.Error{} = error} ->
        Mix.raise(error.message)
    end
  end

  defp maybe(opts, _key, nil), do: opts
  defp maybe(opts, _key, false), do: opts
  defp maybe(opts, :format, :text), do: opts
  defp maybe(opts, key, value), do: Keyword.put(opts, key, value)
end
