# Runnable from the repository root:
#   mix run examples/tutorial_06.exs
#
# The default read does not execute Wasm. A registered extension is this
# library's policy. The sandboxed read needs the native decoder.

IO.puts("command: mix run examples/tutorial_06.exs")

defmodule Tutorial06.TradeId do
  @behaviour F3.Extension

  def decode(_bytes, metadata, :i64) do
    # The file does not name this module. The registration does.
    if metadata.encoding == :custom_wasm and metadata.version == %{major: 1, minor: 0, patch: 0} do
      F3.Column.from_native(:i64, 3, <<1::little-64, 2::little-64, 3::little-64>>, nil)
    else
      {:error, F3.Error.unsupported_encoding(:decode, "extension does not match")}
    end
  end

  def decode(_bytes, _metadata, _type) do
    {:error, F3.Error.unsupported_encoding(:decode, "extension does not match")}
  end
end

{:ok, file} = F3.open("test/fixtures/custom_wasm.f3")

case F3.read(file) do
  {:error, %F3.Error{category: :unsupported_encoding}} ->
    IO.puts("wasm: off")

  other ->
    IO.inspect(other, label: "default read")
end

{:ok, registry} = F3.Registry.start_link()

:ok =
  F3.Registry.register(
    registry,
    %{encoding: :custom_wasm, version: %{major: 1, minor: 0, patch: 0}},
    Tutorial06.TradeId
  )

{:ok, [batch]} = F3.read(file, extensions: registry)
{:ok, rows} = F3.Batch.to_rows(batch)
IO.puts("extension rows:")
IO.inspect(rows, limit: :infinity)

case F3.read(file, wasm: :sandbox, wasm_module_bytes: F3.Wasm.max_module_bytes()) do
  {:ok, [sandbox]} ->
    {:ok, sandbox_rows} = F3.Batch.to_rows(sandbox)
    IO.puts("sandbox rows:")
    IO.inspect(sandbox_rows, limit: :infinity)

  {:error, %F3.Error{category: :native_unavailable}} ->
    IO.puts("wasm: sandbox needs the native decoder")

  {:error, %F3.Error{category: category, message: message}} ->
    IO.puts("sandbox: #{category} #{message}")
end

{:ok, _file} = F3.close(file)
