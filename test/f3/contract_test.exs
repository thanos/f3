defmodule F3.ContractTest do
  use ExUnit.Case, async: true

  doctest F3.Format

  @marker "SECRET_PAYLOAD_MARKER"

  test "postscript layout matches the pinned 32 byte tail" do
    layout = F3.Format.postscript_layout()
    assert Enum.map(layout, &elem(&1, 1)) |> Enum.sum() == F3.Format.postscript_size()
    assert F3.Format.postscript_size() == 32
    assert F3.Format.magic() == "F3"
    assert F3.Format.major_version() == 0
    assert F3.Format.minor_version() == 1
    assert F3.Format.upstream_sha() =~ ~r/^[0-9a-f]{40}$/
  end

  test "version policy accepts only the pinned pair" do
    assert F3.Format.compatible?(0, 1)
    refute F3.Format.compatible?(0, 0)
    refute F3.Format.compatible?(0, 2)
    refute F3.Format.compatible?(1, 1)
    refute F3.Format.compatible?(-1, 1)
    refute F3.Format.compatible?(:major, :minor)
  end

  test "library does not start an application callback" do
    # No `mod:` entry. OTP either omits the key or stores an empty list.
    # Neither form names a callback module.
    assert Application.spec(:f3, :mod) in [nil, []]
  end

  test "missing path is not found and a directory is rejected" do
    assert {:error, %F3.Error{category: :not_found}} =
             F3.open("test/fixtures/does-not-exist-#{System.unique_integer([:positive])}.f3")

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.open("test")
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.open(12)
  end

  test "memory source does not open the path and hides payload bytes" do
    assert {:ok, file} =
             F3.open("this-path-is-not-a-file", source: {:memory, @marker})

    assert file.origin == :memory
    refute inspect(file) =~ @marker

    assert {:error, %F3.Error{category: :truncated} = error} = F3.schema(file)
    refute error.message =~ @marker
    refute inspect(error) =~ @marker

    assert {:ok, closed} = F3.close(file)
    assert {:ok, ^closed} = F3.close(closed)
    assert {:error, %F3.Error{category: :closed}} = F3.schema(closed)
    assert {:error, %F3.Error{category: :closed}} = F3.read(closed)
    assert {:error, %F3.Error{category: :closed}} = F3.stream(closed)
    assert {:error, %F3.Error{category: :closed}} = F3.metadata(closed)
    assert {:error, %F3.Error{category: :closed}} = F3.inspect(closed)
  end

  test "a short buffer is truncated and row access stays unimplemented" do
    assert {:ok, file} = F3.open({:memory, "not an f3 file"})

    assert {:error, %F3.Error{category: :truncated}} = F3.schema(file)
    assert {:error, %F3.Error{category: :truncated}} = F3.metadata(file)
    assert {:error, %F3.Error{category: :truncated}} = F3.inspect(file)

    for {fun, args} <- [
          {:read, [file]},
          {:read, [file, [columns: ["symbol"]]]},
          {:stream, [file]},
          {:stream, [file, [batch_size: 8]]}
        ] do
      assert {:error, %F3.Error{category: category}} = apply(F3, fun, args)
      assert category in [:native_unavailable, :truncated]
    end

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.read(file, :bad)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.stream(file, :bad)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.inspect(file, :bad)
    assert {:ok, []} = F3.Batch.to_rows(%F3.Batch{})
    assert {:error, %F3.Error{category: :not_implemented}} = F3.Writer.open("out.f3")
    assert {:error, %F3.Error{category: :not_implemented}} = F3.Writer.write(:writer, [])
    assert {:error, %F3.Error{category: :not_implemented}} = F3.Writer.close(:writer)
  end

  test "memory pread honors offset and length without reading past the buffer" do
    assert {:ok, source} = F3.IO.Memory.open("abcdefghij")
    assert {:ok, 10} = F3.IO.Memory.size(source)
    assert {:ok, "ef"} = F3.IO.Memory.pread(source, 4, 2)
    assert {:ok, "efghij"} = F3.IO.Memory.pread(source, 4, 100)
    assert {:ok, ""} = F3.IO.Memory.pread(source, 10, 4)
    assert {:ok, ""} = F3.IO.Memory.pread(source, 0, 0)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.Memory.pread(source, -1, 1)

    assert {:ok, closed} = F3.IO.Memory.close(source)
    assert {:ok, _} = F3.IO.Memory.close(closed)
    assert {:error, %F3.Error{category: :closed}} = F3.IO.Memory.size(closed)
    assert {:error, %F3.Error{category: :closed}} = F3.IO.Memory.pread(closed, 0, 1)
    refute inspect(source) =~ "abcdefghij"
  end

  test "local pread is capped at the size recorded at open" do
    path = Path.join(System.tmp_dir!(), "f3-stage0-#{System.unique_integer([:positive])}")
    File.write!(path, "abcdefghij")
    on_exit(fn -> File.rm(path) end)

    assert {:ok, source} = F3.IO.Local.open(path)
    assert {:ok, 10} = F3.IO.Local.size(source)
    assert {:ok, "cdef"} = F3.IO.Local.pread(source, 2, 4)
    assert {:ok, "ij"} = F3.IO.Local.pread(source, 8, 50)
    assert {:ok, ""} = F3.IO.Local.pread(source, 11, 1)

    assert {:ok, file} = F3.open(path)
    assert file.origin == path
    assert {:ok, closed} = F3.close(file)
    assert closed.closed
    assert {:ok, _} = F3.close(closed)
  end

  test "native scaffold follows the compile-time build flag" do
    if System.get_env("F3_BUILD_NATIVE") == "1" do
      assert F3.Native.available?()
      assert {:ok, {"f3_native", version}} = F3.Native.info()
      assert version =~ ~r/^\d+\.\d+\.\d+$/
    else
      refute F3.Native.available?()
      assert {:error, :native_unavailable} = F3.Native.info()
    end
  end
end
