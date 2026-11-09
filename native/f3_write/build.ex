defmodule F3.Writer.Build do
  @moduledoc false

  # Compiles native/f3_write as a bin of the pinned fff-poc checkout.
  # A freestanding Cargo resolve does not compile on nightly-2025-02-24.

  @sha "bd92506447dc1333820cfe9a34ebbf497fe0219e"
  @toolchain "nightly-2025-02-24"
  @release_host "https://github.com/thanos/f3/releases/download"

  @spec install!() :: :ok
  def install! do
    if System.get_env("F3_BUILD_NATIVE") == "1" do
      compile_source!()
    else
      fetch_precompiled!()
    end
  end

  @doc false
  @spec classify(String.t()) :: {:ok, String.t()} | :error
  def classify(arch) when is_binary(arch) do
    case String.split(arch, "-") do
      [cpu, "apple", "darwin" <> _] -> {:ok, "#{cpu}-apple-darwin"}
      [cpu, _vendor, "linux", abi] -> linux_triple(cpu, abi)
      _other -> :error
    end
  end

  @doc false
  @spec archive_for(map(), String.t()) :: {:ok, String.t(), String.t()} | :error
  def archive_for(checksums, target) when is_map(checksums) and is_binary(target) do
    suffix = "-#{target}.tar.gz"

    case Enum.find(checksums, fn {name, _hash} -> String.ends_with?(name, suffix) end) do
      {name, "sha256:" <> hash} when hash != "" -> {:ok, name, hash}
      _other -> :error
    end
  end

  @doc false
  @spec release_version(String.t(), String.t()) :: String.t()
  def release_version(name, target) do
    name
    |> String.trim_trailing("-#{target}.tar.gz")
    |> String.trim_leading("f3_write-v")
  end

  @doc false
  @spec unpack_writer!(Path.t(), Path.t()) :: :ok
  def unpack_writer!(archive, dest) do
    dir = Path.join(System.tmp_dir!(), "f3_write-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)

    case :erl_tar.extract(to_charlist(archive), [:compressed, {:cwd, to_charlist(dir)}]) do
      :ok ->
        File.mkdir_p!(Path.dirname(dest))
        File.cp!(Path.join(dir, "f3_write"), dest)
        File.chmod!(dest, 0o755)
        File.rm_rf!(dir)
        :ok

      {:error, reason} ->
        File.rm_rf!(dir)
        raise "could not unpack #{Path.basename(archive)}: #{inspect(reason)}"
    end
  end

  defp compile_source! do
    root = File.cwd!()
    source = Path.join(root, "native/f3_write/src/main.rs")
    output = Path.join(root, "priv/native/f3_write")

    if fresh?(output, source) do
      :ok
    else
      dest = ensure_checkout(root)
      bin_dir = Path.join(dest, "fff-poc/src/bin")
      File.mkdir_p!(bin_dir)
      File.cp!(source, Path.join(bin_dir, "f3_write.rs"))
      cargo = cargo_bin()
      target = Path.join(dest, "target")

      {log, status} =
        System.cmd(
          cargo,
          ["build", "--locked", "--release", "-p", "fff-poc", "--bin", "f3_write"],
          cd: dest,
          env: [
            {"PATH", Path.dirname(cargo) <> ":" <> strip_asdf(System.get_env("PATH", ""))},
            {"RUSTC", Path.join(Path.dirname(cargo), "rustc")},
            {"CARGO", cargo},
            {"CARGO_TARGET_DIR", target}
          ],
          stderr_to_stdout: true
        )

      if status != 0 do
        raise "f3_write failed to compile on #{@toolchain}\n#{log}"
      end

      File.mkdir_p!(Path.dirname(output))
      File.cp!(Path.join(target, "release/f3_write"), output)
      File.chmod!(output, 0o755)
      :ok
    end
  end

  defp fetch_precompiled! do
    checksums = read_checksums!()
    target = target_triple()

    case archive_for(checksums, target) do
      {:ok, name, hash} -> install_archive(name, hash, target)
      :error -> missing_archive!(target)
    end
  end

  defp install_archive(name, hash, target) do
    dest = Path.join(File.cwd!(), "priv/native/f3_write")

    if fresh_binary?(dest, hash) do
      :ok
    else
      download_archive!(name, hash, target, dest)
    end
  end

  defp download_archive!(name, hash, target, dest) do
    version = release_version(name, target)
    url = "#{@release_host}/v#{version}/#{name}"
    archive = Path.join(System.tmp_dir!(), name)
    curl = System.find_executable("curl") || raise "downloading f3_write requires curl"

    {log, status} =
      System.cmd(
        curl,
        ["--retry", "5", "--retry-all-errors", "--retry-delay", "2", "-fsSL", "-o", archive, url],
        stderr_to_stdout: true
      )

    if status != 0 do
      File.rm(archive)
      raise "could not download #{name}\n#{log}"
    end

    actual = sha256(archive)

    if actual == hash do
      unpack_writer!(archive, dest)
      File.write!(dest <> ".sha256", hash)
      File.rm(archive)
      :ok
    else
      File.rm(archive)
      raise "checksum mismatch for #{name}"
    end
  end

  defp read_checksums! do
    path = Path.expand("../../checksum-f3_write.exs", __DIR__)
    {checksums, _binding} = Code.eval_file(path)

    if is_map(checksums) do
      checksums
    else
      raise "checksum-f3_write.exs must evaluate to a map"
    end
  end

  defp target_triple do
    arch = :erlang.system_info(:system_architecture) |> List.to_string()

    case classify(arch) do
      {:ok, triple} -> triple
      :error -> missing_archive!(arch)
    end
  end

  defp missing_archive!(target) do
    raise "no precompiled f3_write for #{target}. Set F3_BUILD_NATIVE=1 to compile it."
  end

  defp fresh_binary?(dest, hash) do
    stamp = dest <> ".sha256"
    File.regular?(dest) and File.regular?(stamp) and String.trim(File.read!(stamp)) == hash
  end

  defp sha256(path) do
    path
    |> File.read!()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp linux_triple(cpu, "gnu" <> _), do: {:ok, "#{cpu}-unknown-linux-gnu"}
  defp linux_triple(_cpu, _abi), do: :error

  defp fresh?(output, source) do
    File.regular?(output) and File.stat!(output).mtime >= File.stat!(source).mtime
  end

  defp cargo_bin do
    rustup =
      System.find_executable("rustup") || Path.join(System.user_home!(), ".cargo/bin/rustup")

    unless File.regular?(rustup) do
      raise "f3_write requires rustup and the #{@toolchain} toolchain"
    end

    {rustc, status} = System.cmd(rustup, ["which", "--toolchain", @toolchain, "rustc"])

    if status != 0 do
      raise "install the writer toolchain with: rustup toolchain install #{@toolchain}\n#{rustc}"
    end

    Path.join(Path.dirname(String.trim(rustc)), "cargo")
  end

  defp ensure_checkout(root) do
    dest = Path.join(root, "tmp/upstream-f3")

    unless File.dir?(Path.join(dest, ".git")) do
      File.mkdir_p!(Path.dirname(dest))
      System.cmd("git", ["init", dest], stderr_to_stdout: true)

      System.cmd("git", [
        "-C",
        dest,
        "remote",
        "add",
        "origin",
        "https://github.com/future-file-format/F3.git"
      ])
    end

    {current, _} = System.cmd("git", ["-C", dest, "rev-parse", "HEAD"], stderr_to_stdout: true)

    if String.trim(current) != @sha do
      {log, status} =
        System.cmd("git", ["-C", dest, "fetch", "--depth", "1", "origin", @sha],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("could not fetch pinned F3\n#{log}")

      {log, status} =
        System.cmd("git", ["-C", dest, "checkout", "--detach", "FETCH_HEAD"],
          stderr_to_stdout: true
        )

      if status != 0, do: raise("could not check out pinned F3\n#{log}")

      System.cmd("git", ["-C", dest, "submodule", "update", "--init", "--recursive"],
        stderr_to_stdout: true
      )
    end

    dest
  end

  defp strip_asdf(path) do
    path
    |> String.split(":")
    |> Enum.reject(&String.contains?(&1, ".asdf/shims"))
    |> Enum.join(":")
  end
end
