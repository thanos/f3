defmodule F3.MixProject do
  use Mix.Project

  @version "0.0.1"
  @upstream "https://github.com/future-file-format/F3"
  @paper "https://doi.org/10.1145/3749163"

  def project do
    stamp_native_flag()
    install_writer()

    [
      app: :f3,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      aliases: aliases(),
      test_coverage: [summary: [threshold: 90]],
      name: "F3",
      homepage_url: @paper
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  def cli do
    [
      preferred_envs: [ci: :test]
    ]
  end

  # F3.Native reads F3_BUILD_NATIVE while it compiles. Mix only recompiles a
  # module when a source or an @external_resource changes, so a later
  # `mix test` would keep the previous beam. Rewriting this stamp when the
  # flag changes invalidates that beam.
  # Runs from project/0, before Mix has pushed this config, so the helper
  # must not call Mix.Project.build_structure/0. Compile later symlinks priv.
  defp install_writer do
    if System.get_env("F3_BUILD_NATIVE") == "1" do
      unless Code.ensure_loaded?(F3.Writer.Build) do
        Code.compile_file(Path.join(__DIR__, "native/f3_write/build.ex"))
      end

      F3.Writer.Build.install!()
    end
  end

  defp stamp_native_flag do
    path = Path.join(__DIR__, "native/f3_native/.f3_build_native")
    stamp = System.get_env("F3_BUILD_NATIVE") || "0"
    previous = if File.regular?(path), do: File.read!(path), else: nil

    if previous != stamp do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, stamp)
    end
  end

  defp deps do
    [
      {:rustler, "~> 0.38.0", optional: true},
      {:ex_doc, "~> 0.38", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.2", only: :test}
    ]
  end

  defp description do
    """
    Experimental Elixir library for the F3 columnar file format.
    Reading CASCADE row data and writing a local file need the optional native build.
    Upstream F3 is a research prototype.
    """
  end

  defp package do
    [
      name: "f3",
      licenses: ["MIT"],
      links: %{
        "Upstream F3" => @upstream,
        "Paper" => @paper
      },
      files: ~w(
        lib
        native/f3_native/src
        native/f3_native/Cargo.toml
        native/f3_native/README.md
        mix.exs
        README.md
        LICENSE
        NOTICE
        CHANGELOG.md
      )
    ]
  end

  defp aliases do
    [
      # Same checks as the required CI job. Mix stops the alias at the first
      # non-zero step. ExUnit stops at the first failed test.
      ci: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "credo --strict",
        "test --cover --max-failures 1",
        "docs"
      ]
    ]
  end

  defp docs do
    [
      main: "overview",
      extras: [
        {"README.md", [filename: "overview", title: "Overview"]},
        {"CHANGELOG.md", [title: "Changelog"]},
        {"docs/upstream-compatibility.md", [title: "Upstream compatibility"]},
        {"docs/architecture.md", [title: "Architecture"]},
        {"docs/feature-matrix.md", [title: "Feature matrix"]},
        {"docs/security.md", [title: "Security"]},
        {"docs/decisions/0001-hybrid-elixir-rust.md", [title: "ADR 0001"]},
        {"docs/tutorials/README.md", [filename: "tutorials", title: "Tutorials"]},
        {"docs/tutorials/01-why-f3.md", [title: "Why F3?"]},
        {"docs/tutorials/02-anatomy-of-an-f3-file.md", [title: "Anatomy of an F3 file"]},
        {"docs/tutorials/03-your-first-f3-file-in-elixir.md",
         [title: "Your first F3 file in Elixir"]},
        {"docs/tutorials/04-streaming-and-column-projection.md",
         [title: "Streaming and column projection"]},
        {"docs/tutorials/05-writing-f3-from-elixir.md", [title: "Writing F3 from Elixir"]},
        {"docs/tutorials/06-custom-encodings-and-wasm.md",
         [title: "Taking the decoder with the data"]},
        {"docs/tutorials/publication-plan.md", [title: "Publication plan"]},
        {"docs/test-reports/stage-0.md", [title: "Stage 0 test report"]},
        {"docs/test-reports/stage-1.md", [title: "Stage 1 test report"]},
        {"docs/test-reports/stage-2.md", [title: "Stage 2 test report"]},
        {"docs/test-reports/stage-3.md", [title: "Stage 3 test report"]},
        {"docs/test-reports/stage-4.md", [title: "Stage 4 test report"]}
      ]
    ]
  end
end
