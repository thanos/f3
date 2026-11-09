defmodule F3.Writer.BuildTest do
  use ExUnit.Case, async: true

  test "maps the release targets" do
    assert F3.Writer.Build.classify("aarch64-apple-darwin24.5.0") ==
             {:ok, "aarch64-apple-darwin"}

    assert F3.Writer.Build.classify("x86_64-pc-linux-gnu") ==
             {:ok, "x86_64-unknown-linux-gnu"}

    assert F3.Writer.Build.classify("aarch64-unknown-linux-gnu") ==
             {:ok, "aarch64-unknown-linux-gnu"}

    assert F3.Writer.Build.classify("x86_64-pc-windows-msvc") == :error
  end

  test "selects the writer archive and its version" do
    checksums = %{
      "f3_write-v0.1.0-aarch64-apple-darwin.tar.gz" => "sha256:abc",
      "f3_write-v0.1.0-x86_64-unknown-linux-gnu.tar.gz" => "sha256:def"
    }

    assert {:ok, name, "abc"} =
             F3.Writer.Build.archive_for(checksums, "aarch64-apple-darwin")

    assert name == "f3_write-v0.1.0-aarch64-apple-darwin.tar.gz"

    assert F3.Writer.Build.release_version(name, "aarch64-apple-darwin") == "0.1.0"

    assert F3.Writer.Build.archive_for(checksums, "aarch64-unknown-linux-gnu") == :error
  end

  test "unpacks the writer name the release archive uses" do
    dir = tmp!("unpack")
    archive = Path.join(dir, "f3_write-v0.1.0-aarch64-apple-darwin.tar.gz")
    dest = Path.join(dir, "out/f3_write")

    :ok =
      :erl_tar.create(to_charlist(archive), [{~c"f3_write", "writer-bytes"}], [:compressed])

    assert :ok = F3.Writer.Build.unpack_writer!(archive, dest)
    assert File.read!(dest) == "writer-bytes"
    assert Bitwise.band(File.stat!(dest).mode, 0o111) != 0
  end

  test "checksum script writes maps the installer can read" do
    input = tmp!("archives")
    output = tmp!("checksums")
    writer = Path.join(input, "f3_write-v0.1.0-aarch64-apple-darwin.tar.gz")
    nif = Path.join(input, "libf3_native-v0.1.0-nif-2.17-aarch64-apple-darwin.so.tar.gz")
    File.write!(writer, "writer")
    File.write!(nif, "nif")

    script = Path.expand("scripts/release/write_checksums.exs")
    {log, status} = System.cmd("elixir", [script, input], cd: output, stderr_to_stdout: true)
    assert status == 0, log

    {checksums, _} = Code.eval_file(Path.join(output, "checksum-f3_write.exs"))

    assert {:ok, "f3_write-v0.1.0-aarch64-apple-darwin.tar.gz", hash} =
             F3.Writer.Build.archive_for(checksums, "aarch64-apple-darwin")

    assert hash == sha256("writer")

    {native, _} = Code.eval_file(Path.join(output, "checksum-Elixir.F3.Native.exs"))
    nif_name = "libf3_native-v0.1.0-nif-2.17-aarch64-apple-darwin.so.tar.gz"
    assert native[nif_name] == "sha256:" <> sha256("nif")
  end

  test "checksum script rejects a directory with no archives" do
    empty = tmp!("empty")
    script = Path.expand("scripts/release/write_checksums.exs")
    {_log, status} = System.cmd("elixir", [script, empty], stderr_to_stdout: true)
    assert status == 1
  end

  defp tmp!(name) do
    dir = Path.join(System.tmp_dir!(), "f3-#{name}-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  defp sha256(bytes) do
    :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  end
end
