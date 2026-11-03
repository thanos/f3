defmodule F3.ManifestTest do
  use ExUnit.Case, async: true

  @manifest "test/fixtures/manifest.json"

  test "committed fixtures match the upstream writer manifest" do
    assert File.regular?(@manifest), "run scripts/fixtures/generate.sh before testing fixtures"

    assert {:ok, manifest} = @manifest |> File.read!() |> JSON.decode()
    assert manifest["upstream_sha"] == F3.Format.upstream_sha()
    assert manifest["generator"] == "scripts/fixtures/generate.sh"
    assert is_list(manifest["fixtures"])
    assert manifest["fixtures"] != []

    names =
      Map.new(manifest["fixtures"], fn fixture ->
        assert fixture["name"] =~ ~r/^[a-z0-9_]+\.f3$/
        assert is_binary(fixture["sha256"])
        assert is_integer(fixture["bytes"])
        assert is_list(fixture["rows"])
        assert is_binary(fixture["notes"])

        path = Path.join("test/fixtures", fixture["name"])
        bytes = File.read!(path)
        assert byte_size(bytes) == fixture["bytes"]
        assert byte_size(bytes) >= F3.Format.postscript_size()

        sha =
          :crypto.hash(:sha256, bytes)
          |> Base.encode16(case: :lower)

        assert sha == fixture["sha256"]
        assert String.ends_with?(bytes, F3.Format.magic())
        assert_postscript(bytes)
        {fixture["name"], fixture}
      end)

    assert Map.has_key?(names, "small.f3")

    for skipped <- manifest["skipped"] do
      assert is_binary(skipped["name"])
      assert is_binary(skipped["reason"])
      assert String.trim(skipped["reason"]) != ""
      refute File.exists?(Path.join("test/fixtures", skipped["name"]))
    end
  end

  defp assert_postscript(bytes) do
    size = F3.Format.postscript_size()
    tail = binary_part(bytes, byte_size(bytes) - size, size)

    {fields, rest} =
      Enum.reduce(F3.Format.postscript_layout(), {[], tail}, fn {name, width}, {acc, rest} ->
        <<raw::binary-size(^width), rest::binary>> = rest
        {[{name, raw} | acc], rest}
      end)

    assert rest == ""
    fields = Map.new(fields)
    assert fields.magic == F3.Format.magic()

    <<major::little-unsigned-integer-size(16)>> = fields.major_version
    <<minor::little-unsigned-integer-size(16)>> = fields.minor_version
    assert F3.Format.compatible?(major, minor)
  end
end
