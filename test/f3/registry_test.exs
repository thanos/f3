defmodule F3.RegistryTest do
  use ExUnit.Case, async: false

  defmodule Trade do
    @behaviour F3.Extension

    def decode(<<1>>, metadata, :i64) do
      assert metadata.encoding == :custom_wasm
      assert metadata.version == %{major: 1, minor: 0, patch: 0}
      assert metadata.wasm_id == 0
      assert metadata.compression == :uncompressed
      F3.Column.from_native(:i64, 1, <<7::signed-little-64>>, nil)
    end

    def decode(_bytes, _metadata, _type) do
      {:error, F3.Error.corrupt(:decode, "extension refused")}
    end
  end

  defmodule Cascade do
    @behaviour F3.Extension

    def decode(_bytes, metadata, type) do
      assert metadata.version == %{major: 0, minor: 22, patch: 0}

      case type do
        :i64 ->
          F3.Column.from_native(:i64, 3, <<1::little-64, 2::little-64, 3::little-64>>, nil)

        :utf8 ->
          F3.Column.from_native(:utf8, 3, ["A", "B", "C"], nil)

        :f64 ->
          F3.Column.from_native(
            :f64,
            3,
            <<0.0::little-float-64, 0.0::little-float-64, 0.0::little-float-64>>,
            nil
          )
      end
    end
  end

  defmodule Other do
    @behaviour F3.Extension

    def decode(_bytes, _metadata, _type) do
      {:error, F3.Error.corrupt(:decode, "other")}
    end
  end

  test "the committed wasm fixture is refused until sandbox is requested" do
    Application.delete_env(:f3, :decoder)
    {:ok, file} = F3.open("test/fixtures/custom_wasm.f3")
    {:ok, meta} = F3.metadata(file)
    section = Enum.find(meta.optional_sections, &(&1.name == "WASMBinaries"))
    {:ok, agent} = Agent.start_link(fn -> [] end)
    tapped = tap_file("test/fixtures/custom_wasm.f3", agent)

    assert {:error, %F3.Error{category: :unsupported_encoding}} = F3.read(tapped)
    refute section_hit?(Agent.get(agent, & &1), section)
    assert {:error, %F3.Error{category: :unsupported_encoding}} = F3.stream(file)
    assert {:error, %F3.Error{category: :native_unavailable}} = F3.read(file, wasm: :sandbox)
  end

  test "register, lookup, unregister, and a full table" do
    assert {:error, %F3.Error{category: :invalid_argument}} = F3.Registry.start_link(capacity: 0)
    assert {:ok, pid} = F3.Registry.start_link(capacity: 1)
    key = %{encoding: :custom_wasm, version: %{major: 1, minor: 0, patch: 0}, wasm_id: 0}
    assert :ok = F3.Registry.register(pid, key, Trade)
    assert :ok = F3.Registry.register(pid, key, Trade)

    assert {:ok, Trade} =
             F3.Registry.lookup(pid, %{
               encoding: :custom_wasm,
               version: %{major: 1, minor: 0, patch: 0},
               wasm_id: 0
             })

    other = %{encoding: :cascade, version: %{major: 0, minor: 21, patch: 0}}

    assert {:error, %F3.Error{category: :resource_limit}} =
             F3.Registry.register(pid, other, Other)

    assert :error = F3.Registry.lookup(pid, Map.put(other, :wasm_id, nil))
    assert :ok = F3.Registry.unregister(pid, key)
    assert :ok = F3.Registry.unregister(pid, key)
    assert :error = F3.Registry.lookup(pid, key)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Registry.register(pid, %{}, Trade)

    assert {:error, %F3.Error{category: :invalid_argument}} =
             F3.Registry.register(:nope, key, Trade)

    GenServer.stop(pid)
    assert :error = F3.Registry.lookup(pid, key)
    assert :error = F3.Registry.lookup(nil, key)
  end

  test "wasm_id is optional and registries do not share rows" do
    {:ok, left} = F3.Registry.start_link()
    {:ok, right} = F3.Registry.start_link()
    wide = %{encoding: :custom_wasm, version: %{major: 1, minor: 0, patch: 0}}
    assert :ok = F3.Registry.register(left, wide, Trade)

    assert {:ok, Trade} =
             F3.Registry.lookup(left, Map.put(wide, :wasm_id, 4))

    assert :error = F3.Registry.lookup(right, Map.put(wide, :wasm_id, 4))
    exact = Map.put(wide, :wasm_id, 1)
    assert :ok = F3.Registry.register(left, exact, Other)

    assert {:ok, Other} =
             F3.Registry.lookup(left, %{
               encoding: :custom_wasm,
               version: wide.version,
               wasm_id: 1,
               compression: :uncompressed
             })
  end

  test "an extension matches before wasm and a mismatch does not" do
    {:ok, pid} = F3.Registry.start_link()
    version = %{major: 1, minor: 0, patch: 0}

    assert :ok =
             F3.Registry.register(
               pid,
               %{encoding: :custom_wasm, version: version, wasm_id: 0},
               Trade
             )

    plan = %{
      versions: [%{encoding: :custom_wasm, version: version}],
      wasm: :sandbox,
      extensions: pid,
      operation: :read
    }

    unit = %{encoding: :custom_wasm, compression: :uncompressed, wasm_id: 0}
    assert {:ok, {:extension, Trade}} = F3.Dispatch.choose(unit, plan)
    assert {:ok, column} = Trade.decode(<<1>>, metadata(unit, version), :i64)
    assert F3.Column.value(column, 0) == 7

    assert {:error, %F3.Error{message: "extension refused"}} =
             Trade.decode(<<2>>, metadata(unit, version), :i64)

    assert {:ok, :wasm} =
             F3.Dispatch.choose(%{unit | wasm_id: 1}, %{plan | extensions: nil})

    assert {:error, %F3.Error{category: :corrupt}} =
             F3.Dispatch.choose(unit, %{plan | versions: []})

    assert {:error, %F3.Error{message: message}} =
             F3.Dispatch.choose(
               %{encoding: :cascade, compression: :uncompressed, wasm_id: nil},
               %{
                 plan
                 | versions: [%{encoding: :cascade, version: %{major: 0, minor: 22, patch: 0}}],
                   wasm: :off,
                   extensions: nil
               }
             )

    assert message =~ "cascade"

    assert {:error, %F3.Error{category: :unsupported_encoding}} =
             F3.Dispatch.choose(
               %{encoding: :cascade, compression: :gzip, wasm_id: nil},
               %{
                 plan
                 | versions: [%{encoding: :cascade, version: %{major: 0, minor: 21, patch: 0}}]
               }
             )

    refute F3.Dispatch.cascade_native?(%{major: 0, minor: 22, patch: 0})
    assert F3.Dispatch.cascade_native?(%{major: 0, minor: 21, patch: 0})
    assert F3.Dispatch.cascade_native?(%{major: 0, minor: 20, patch: 0})
    assert F3.Dispatch.cascade_version() == %{major: 0, minor: 21, patch: 0}
  end

  test "two tasks can register while a read runs" do
    stub = fn ->
      Mox.stub(F3.Decoder.Mock, :decode, fn _bytes, _compression, type ->
        case type do
          :i64 -> F3.Column.from_native(:i64, 3, <<1::64, 2::64, 3::64>>, nil)
          :utf8 -> F3.Column.from_native(:utf8, 3, ["AAPL", "MSFT", "GOOG"], nil)
          :f64 -> F3.Column.from_native(:f64, 3, <<0::float-64, 0::float-64, 0::float-64>>, nil)
        end
      end)
    end

    Application.put_env(:f3, :decoder, F3.Decoder.Mock)
    on_exit(fn -> Application.delete_env(:f3, :decoder) end)
    stub.()
    {:ok, pid} = F3.Registry.start_link()
    {:ok, file} = F3.open("test/fixtures/small.f3")

    first =
      Task.async(fn ->
        F3.Registry.register(
          pid,
          %{encoding: :custom_wasm, version: %{major: 1, minor: 0, patch: 0}},
          Trade
        )
      end)

    second =
      Task.async(fn ->
        F3.Registry.register(
          pid,
          %{encoding: :custom_wasm, version: %{major: 1, minor: 1, patch: 0}, wasm_id: 2},
          Other
        )
      end)

    assert {:ok, [%F3.Batch{num_rows: 3}]} = F3.read(file, extensions: pid)
    assert :ok = Task.await(first)
    assert :ok = Task.await(second)
  end

  test "the wasm section parser does not surface lib urls" do
    {:ok, file} = F3.open("test/fixtures/small.f3")
    {:ok, meta} = F3.metadata(file)
    section = Enum.find(meta.optional_sections, &(&1.name == "WASMBinaries"))

    {:ok, bytes} = file.source_module.pread(file.source_state, section.offset, section.size)
    assert {:ok, modules} = F3.Wasm.modules(bytes)

    assert Enum.all?(modules, fn entry ->
             Enum.sort(Map.keys(entry)) == [:compression, :offset, :size]
           end)

    assert F3.Wasm.fuel() == 5_000_000
    assert F3.Wasm.memory_bytes() == 8 * 1024 * 1024
    assert F3.Wasm.default_module_bytes() == 1024 * 1024
    assert F3.Wasm.max_module_bytes() == 16 * 1024 * 1024

    plan = %{
      file: file,
      sections: meta.optional_sections,
      module_cap: F3.Wasm.default_module_bytes(),
      operation: :read
    }

    assert {:error, %F3.Error{category: :unsupported_encoding}} =
             F3.Wasm.decode(
               plan,
               %{wasm_id: 0, compression: :uncompressed, num_rows: 1},
               <<>>,
               :list32
             )

    assert {:error, %F3.Error{message: "wasm section is missing"}} =
             F3.Wasm.decode(
               %{plan | sections: []},
               %{wasm_id: 0, num_rows: 1, compression: :uncompressed},
               <<>>,
               :i64
             )

    assert {:error, %F3.Error{category: :corrupt}} = F3.Wasm.modules(<<1, 2, 3, 4>>)
    :erlang.trace(self(), true, [:call])
    :erlang.trace_pattern({:httpc, :_, :_}, true, [:local])
    assert {:ok, _again} = F3.Wasm.modules(bytes)
    :erlang.trace(self(), false, [:call])
    refute_received {:trace, _, :call, {:httpc, _, _}}
  end

  test "a newer cascade version uses an extension and does not read payloads when refused" do
    Application.delete_env(:f3, :decoder)
    binary = File.read!("test/fixtures/small.f3")
    <<head::binary-size(3424), 21, tail::binary>> = binary
    newer = head <> <<22>> <> tail
    {:ok, file} = F3.open({:memory, newer})

    assert {:error, %F3.Error{category: :unsupported_encoding}} = F3.read(file)
    assert {:error, %F3.Error{category: :unsupported_encoding}} = F3.stream(file)

    {:ok, pid} = F3.Registry.start_link()
    version = %{major: 0, minor: 22, patch: 0}

    assert :ok =
             F3.Registry.register(
               pid,
               %{encoding: :cascade, version: version},
               __MODULE__.Cascade
             )

    assert {:ok, [%F3.Batch{num_rows: 3}]} = F3.read(file, extensions: pid)
    assert {:ok, stream} = F3.stream(file, extensions: pid)
    assert [%F3.Batch{num_rows: 3}] = Enum.to_list(stream)
  end

  test "wasm loading reports caps, a short section, and a missing host" do
    section = wasm_binaries(100, 8, 0)
    binary = :binary.copy(<<0>>, 100) <> "abcdefgh" <> :binary.copy(<<0>>, 92) <> section
    {:ok, file} = F3.open({:memory, binary})

    plan = %{
      file: file,
      sections: [
        %{
          name: "WASMBinaries",
          offset: 200,
          size: byte_size(section),
          compression: :uncompressed
        }
      ],
      module_cap: F3.Wasm.default_module_bytes(),
      operation: :read
    }

    unit = %{wasm_id: 0, compression: :uncompressed, num_rows: 1}

    assert {:error, %F3.Error{category: :native_unavailable}} =
             F3.Wasm.decode(plan, unit, <<1>>, :i64)

    assert {:error, %F3.Error{message: "wasm_id is past the section"}} =
             F3.Wasm.decode(plan, %{unit | wasm_id: 3}, <<1>>, :i64)

    assert {:error, %F3.Error{category: :native_unavailable}} =
             F3.Wasm.decode(plan, %{unit | wasm_id: nil}, <<1>>, :i64)

    huge = wasm_binaries(100, 17 * 1024 * 1024, 0)
    {:ok, huge_file} = F3.open({:memory, :binary.copy(<<0>>, 200) <> huge})

    assert {:error, %F3.Error{category: :resource_limit}} =
             F3.Wasm.decode(
               %{
                 plan
                 | file: huge_file,
                   sections: [
                     %{
                       name: "WASMBinaries",
                       offset: 200,
                       size: byte_size(huge),
                       compression: :uncompressed
                     }
                   ]
               },
               unit,
               <<1>>,
               :i64
             )

    assert {:error, %F3.Error{category: :resource_limit}} =
             F3.Wasm.decode(%{plan | module_cap: 4}, unit, <<1>>, :i64)

    zstd = %{hd(plan.sections) | compression: :zstd}

    assert {:error, %F3.Error{category: :unsupported_encoding}} =
             F3.Wasm.decode(%{plan | sections: [zstd]}, unit, <<1>>, :i64)

    short = wasm_binaries(100, 8, 0)
    {:ok, short_file} = F3.open({:memory, short})

    assert {:error, %F3.Error{category: :truncated}} =
             F3.Wasm.decode(
               %{
                 plan
                 | file: short_file,
                   sections: [
                     %{
                       name: "WASMBinaries",
                       offset: 0,
                       size: byte_size(short),
                       compression: :uncompressed
                     }
                   ]
               },
               unit,
               <<1>>,
               :i64
             )

    assert {:ok, [%{compression: :zstd}]} = F3.Wasm.modules(wasm_binaries(1, 1, 1))
    assert {:ok, [%{compression: :lz4}]} = F3.Wasm.modules(wasm_binaries(1, 1, 2))
    assert {:ok, [%{compression: {:unknown, 9}}]} = F3.Wasm.modules(wasm_binaries(1, 1, 9))
    assert {:error, %F3.Error{category: :corrupt}} = F3.Wasm.modules(:nope)
  end

  test "lookup and shutdown tolerate a table that is already gone" do
    {:ok, pid} = F3.Registry.start_link()
    stale = :ets.new(:f3_stale_registry, [:public])
    GenServer.stop(pid)

    if :ets.whereis(:f3_registry_index) == :undefined do
      :ets.new(:f3_registry_index, [:named_table, :public, :set])
    end

    :ets.insert(:f3_registry_index, {pid, stale})
    :ets.delete(stale)

    assert :error =
             F3.Registry.lookup(pid, %{
               encoding: :cascade,
               version: %{major: 0, minor: 0, patch: 0},
               wasm_id: nil
             })

    {:ok, pid} = F3.Registry.start_link()
    :ets.delete(:f3_registry_index)
    GenServer.stop(pid)
  end

  defp wasm_binaries(offset, size, compression) do
    <<
      12::little-32,
      6::little-16,
      8::little-16,
      4::little-16,
      0,
      0,
      8::little-32,
      4::little-32,
      1::little-32,
      16::little-32,
      10::little-16,
      24::little-16,
      8::little-16,
      16::little-16,
      20::little-16,
      0,
      0,
      12::little-signed-32,
      0::32,
      offset::little-64,
      size::little-32,
      compression,
      0,
      0,
      0
    >>
  end

  defp section_hit?(reads, section) do
    Enum.any?(reads, fn {offset, length} ->
      offset < section.offset + section.size and offset + length > section.offset
    end)
  end

  defp tap_file(path, agent) do
    {:ok, memory} = File.read!(path) |> F3.IO.Memory.open()

    %F3.File{
      source_module: F3.ReadTest.Tap,
      source_state: {agent, memory},
      origin: :memory
    }
  end

  defp metadata(unit, version) do
    %{
      encoding: unit.encoding,
      version: version,
      wasm_id: unit.wasm_id,
      compression: unit.compression
    }
  end
end
