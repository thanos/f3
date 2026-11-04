defmodule F3.IOMockTest do
  use ExUnit.Case, async: false

  import Mox

  setup :verify_on_exit!

  test "a mocked source reports a short read and a read error" do
    bytes = File.read!("test/fixtures/small.f3")

    stub_source(byte_size(bytes), fn _state, _offset, length ->
      if length == 32, do: {:ok, binary_part(bytes, byte_size(bytes) - 32, 10)}, else: {:ok, <<>>}
    end)

    assert {:error, %F3.Error{category: :truncated, message: message}} =
             F3.Postscript.decode(mock_file(), 1_000)

    assert message =~ "shorter than 32"

    stub_source(byte_size(bytes), fn _state, offset, length ->
      if length == 32 do
        {:ok, binary_part(bytes, offset, 32)}
      else
        {:ok, <<0>>}
      end
    end)

    assert {:error, %F3.Error{message: "metadata read was shorter than the postscript size"}} =
             F3.metadata(mock_file())

    error = F3.Error.io(:pread, :eio)

    stub_source(byte_size(bytes), fn _state, _offset, _length -> {:error, error} end)
    assert {:error, ^error} = F3.Postscript.decode(mock_file(), 1_000)

    stub_source(byte_size(bytes), fn _state, offset, length ->
      if length == 32 do
        {:ok, binary_part(bytes, offset, 32)}
      else
        {:error, error}
      end
    end)

    assert {:error, ^error} = F3.metadata(mock_file())
  end

  test "closing a mocked source can fail" do
    error = F3.Error.io(:close, :eio)
    stub(F3.IO.Mock, :close, fn _state -> {:error, error} end)
    assert {:error, ^error} = F3.close(mock_file())
  end

  test "the local file system mock returns eof, os errors, and an idempotent close" do
    fs = F3.IO.FileSystemMock

    stub(fs, :stat, fn _path -> {:ok, regular_stat(4)} end)
    stub(fs, :open, fn _path, _modes -> {:ok, :fd} end)
    stub(fs, :pread, fn :fd, _offset, _length -> :eof end)
    stub(fs, :close, fn :fd -> :ok end)

    assert {:ok, source} = F3.IO.Local.open("mocked", file_system: fs)
    assert {:ok, <<>>} = F3.IO.Local.pread(source, 0, 2)
    assert {:ok, closed} = F3.IO.Local.close(source)
    assert {:ok, ^closed} = F3.IO.Local.close(closed)

    stub(fs, :pread, fn :fd, _offset, _length -> {:error, :eio} end)
    assert {:ok, source} = F3.IO.Local.open("mocked", file_system: fs)
    assert {:error, %F3.Error{category: :io, reason: :eio}} = F3.IO.Local.pread(source, 0, 2)

    stub(fs, :close, fn :fd -> {:error, :eio} end)
    assert {:error, %F3.Error{category: :io, reason: :eio}} = F3.IO.Local.close(source)

    stub(fs, :stat, fn _path -> {:error, :eacces} end)

    assert {:error, %F3.Error{category: :io, reason: :eacces}} =
             F3.IO.Local.open("mocked", file_system: fs)

    stub(fs, :stat, fn _path -> {:ok, regular_stat(4)} end)
    stub(fs, :open, fn _path, _modes -> {:error, :enoent} end)
    assert {:error, %F3.Error{category: :not_found}} = F3.IO.Local.open("mocked", file_system: fs)

    stub(fs, :open, fn _path, _modes -> {:error, :eacces} end)

    assert {:error, %F3.Error{category: :io, reason: :eacces}} =
             F3.IO.Local.open("mocked", file_system: fs)

    assert %F3.Error{category: :unsupported_encoding} =
             F3.Error.unsupported_encoding(:postscript, "compressed")

    assert %F3.Error{category: :resource_limit} = F3.Error.resource_limit(:postscript, "capped")
  end

  defp mock_file do
    %F3.File{source_module: F3.IO.Mock, source_state: :mock, origin: :memory}
  end

  defp stub_source(size, pread) do
    stub(F3.IO.Mock, :size, fn _state -> {:ok, size} end)
    stub(F3.IO.Mock, :pread, pread)
    stub(F3.IO.Mock, :close, fn state -> {:ok, state} end)
  end

  defp regular_stat(size) do
    %File.Stat{size: size, type: :regular}
  end
end
