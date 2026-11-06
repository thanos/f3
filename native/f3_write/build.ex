defmodule F3.Writer.Build do
  @moduledoc false

  # Compiles native/f3_write as a bin of the pinned fff-poc checkout.
  # A freestanding Cargo resolve does not compile on nightly-2025-02-24.

  @sha "bd92506447dc1333820cfe9a34ebbf497fe0219e"
  @toolchain "nightly-2025-02-24"

  @spec install!() :: :ok
  def install! do
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
      Mix.Project.build_structure()
      :ok
    end
  end

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
