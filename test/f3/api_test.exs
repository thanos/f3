defmodule F3.ApiTest do
  use ExUnit.Case, async: true

  test "open rejects unknown sources, options, and non-binaries" do
    assert {:error, %F3.Error{category: :invalid_argument, message: "unknown source socket"}} =
             F3.open("unused", source: :socket)

    assert {:error, %F3.Error{message: "unknown source a binary of 3 bytes"}} =
             F3.open("unused", source: "abc")

    assert {:error, %F3.Error{message: "unknown source a tuple of size 2"}} =
             F3.open("unused", source: {1, 2})

    assert {:error, %F3.Error{message: "unknown source an unsupported value"}} =
             F3.open("unused", source: 1)

    assert {:error, %F3.Error{message: "memory source must be a binary"}} =
             F3.open("unused", source: {:memory, :not_a_binary})

    assert {:error, %F3.Error{message: "unknown options: [:extra]"}} =
             F3.open("unused", extra: true)

    assert {:error, %F3.Error{message: "unknown options: [:extra]"}} =
             F3.open({:memory, <<>>}, extra: true)

    assert {:error, %F3.Error{message: "expected a path or {:memory, binary}"}} =
             F3.open({:memory, :not_a_binary})

    assert {:error, %F3.Error{message: "options must be a keyword list"}} =
             F3.open("unused", :bad)

    assert {:error, %F3.Error{message: "expected an F3.File"}} = F3.close(:not_a_file)
  end

  test "metadata calls reject a bad handle, a bad cap, and unknown options" do
    {:ok, file} = F3.open("test/fixtures/small.f3")

    for fun <- [:schema, :metadata, :inspect, :read, :stream] do
      assert {:error, %F3.Error{category: :invalid_argument}} = apply(F3, fun, [:not_a_file])

      assert {:error, %F3.Error{message: "options must be a keyword list"}} =
               apply(F3, fun, [file, :bad])
    end

    assert {:error, %F3.Error{message: "max_metadata_bytes must be a non-negative integer"}} =
             F3.schema(file, max_metadata_bytes: -1)

    assert {:error, %F3.Error{message: "max_metadata_bytes must be a non-negative integer"}} =
             F3.metadata(file, max_metadata_bytes: :big)

    assert {:error, %F3.Error{message: "unknown options: [:columns]"}} =
             F3.inspect(file, columns: ["symbol"])

    assert {:error, %F3.Error{message: "detail must be a boolean"}} =
             F3.inspect(file, detail: :yes)

    assert {:error, %F3.Error{message: "format must be :text or :json"}} =
             F3.inspect(file, format: :yaml)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Postscript.decode(file, -1)

    assert {:error, %F3.Error{category: :invalid_argument}} = F3.Batch.to_rows(%{})
  end

  test "local and memory sources reject bad arguments and a closed handle" do
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.IO.Local.open(:not_a_path)
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.IO.Memory.open(:not_a_binary)

    path = Path.join(System.tmp_dir!(), "f3-api-#{System.unique_integer([:positive])}")
    File.write!(path, "abcdefghij")
    on_exit(fn -> File.rm(path) end)

    {:ok, local} = F3.IO.Local.open(path)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.IO.Local.pread(local, :offset, 1)

    {:ok, closed_local} = F3.IO.Local.close(local)
    assert {:error, %F3.Error{category: :closed}} = F3.IO.Local.size(closed_local)
    assert {:error, %F3.Error{category: :closed}} = F3.IO.Local.pread(closed_local, 0, 1)
    assert inspect(closed_local) =~ "closed: true"

    {:ok, memory} = F3.IO.Memory.open("abcd")
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.IO.Memory.pread(memory, 0, -1)
    {:ok, closed_memory} = F3.IO.Memory.close(memory)
    assert {:error, %F3.Error{category: :closed}} = F3.IO.Memory.size(closed_memory)
    assert inspect(closed_memory) =~ "size: 4"
  end
end
