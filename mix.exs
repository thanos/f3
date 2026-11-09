defmodule F3.MixProject do
  use Mix.Project

  @version "0.1.0"
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
      extra_applications: [:logger, :inets, :ssl, :public_key, :crypto]
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
    alias F3.Writer.Build

    if writer_requested?() do
      unless Code.ensure_loaded?(Build) do
        Code.compile_file(Path.join(__DIR__, "native/f3_write/build.ex"))
      end

      Build.install!()
    end
  end

  # A Hex package ships checksum-f3_write.exs and downloads the helper.
  # This checkout has no checksum file, so Mix compiles the helper only
  # when F3_BUILD_NATIVE=1.
  defp writer_requested? do
    System.get_env("F3_BUILD_NATIVE") == "1" or
      File.regular?(Path.join(__DIR__, "checksum-f3_write.exs"))
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
      {:rustler_precompiled, "~> 0.8.2"},
      {:ex_doc, "~> 0.38", only: [:dev, :test], runtime: false},
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:mox, "~> 1.2", only: :test}
    ]
  end

  defp description do
    """
    Experimental Elixir library for the F3 columnar file format.
    A Hex release downloads precompiled NIFs for macOS Apple silicon and Linux x86_64.
    A git checkout compiles that native code only when F3_BUILD_NATIVE=1.
    Upstream F3 is a research prototype.
    """
  end

  defp package do
    [
      name: "f3",
      licenses: ["MIT"],
      links: %{
        "GitHub" => "https://github.com/thanos/f3",
        "Upstream F3" => @upstream,
        "Paper" => @paper
      },
      files: package_files()
    ]
  end

  # Checksum files are written by the publish workflow just before
  # `mix hex.publish`. A local dry-run has none, and Hex rejects a
  # files entry that matches nothing.
  defp package_files do
    checksums =
      __DIR__
      |> Path.join("checksum-*.exs")
      |> Path.wildcard()
      |> Enum.map(&Path.relative_to(&1, __DIR__))

    ~w(
      lib
      native/f3_native/src
      native/f3_native/Cargo.toml
      native/f3_native/Cargo.lock
      native/f3_native/rust-toolchain.toml
      native/f3_native/README.md
      native/f3_write/src
      native/f3_write/build.ex
      native/f3_write/Cargo.toml
      native/f3_write/rust-toolchain.toml
      mix.exs
      README.md
      LICENSE
      NOTICE
      CHANGELOG.md
    ) ++ checksums
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
      main: "readme",
      before_closing_body_tag: &before_closing_body_tag/1,
      groups_for_extras: [
        "User guide": [~r/docs\/guide\//, "docs/architecture.md", "docs/examples.livemd"],
        Contributing: [
          "CHANGELOG.md",
          "docs/contributing.md",
          ~r/docs\/upstream-compatibility/,
          ~r/docs\/security/,
          ~r/docs\/feature-matrix/,
          ~r/docs\/decisions\//
        ],
        Background: [~r/docs\/tutorials\//, ~r/docs\/test-reports\//]
      ],
      extras: [
        {"README.md", [filename: "readme", title: "README"]},
        {"docs/guide/01-introduction.md", [title: "Introduction"]},
        {"docs/guide/02-quick-start.md", [title: "Quick start"]},
        {"docs/guide/03-configuration.md", [title: "Configuration"]},
        {"docs/guide/04-f3-in-detail.md", [title: "F3 in detail"]},
        {"docs/guide/05-writing.md", [title: "Writing"]},
        {"docs/guide/06-reading.md", [title: "Reading"]},
        {"docs/guide/07-streaming.md", [title: "Streaming"]},
        {"docs/guide/08-decoders.md", [title: "Decoders"]},
        {"docs/guide/09-wasm.md", [title: "Wasm"]},
        {"docs/guide/10-interoperability.md", [title: "Interoperability"]},
        {"docs/guide/11-status-and-roadmap.md", [title: "Status and roadmap"]},
        {"docs/architecture.md", [title: "Architecture"]},
        {"docs/guide/13-examples.md", [title: "Examples"]},
        {"docs/examples.livemd", [title: "Livebook"]},
        {"docs/contributing.md", [title: "Building from source"]},
        {"CHANGELOG.md", [title: "Changelog"]},
        {"docs/upstream-compatibility.md", [title: "Upstream compatibility"]},
        {"docs/security.md", [title: "Security"]},
        {"docs/feature-matrix.md", [title: "Feature matrix"]},
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
        {"docs/tutorials/07-f3-arrow-and-parquet.md", [title: "F3, Apache Arrow, and Parquet"]},
        {"docs/tutorials/08-a-safe-reader-on-the-beam.md",
         [title: "Building a safe binary-file reader on the BEAM"]},
        {"docs/tutorials/09-performance-and-what-remains-experimental.md",
         [title: "Performance, compatibility, and what remains experimental"]},
        {"docs/tutorials/publication-plan.md", [title: "Publication plan"]},
        {"docs/test-reports/stage-0.md", [title: "Stage 0 test report"]},
        {"docs/test-reports/stage-1.md", [title: "Stage 1 test report"]},
        {"docs/test-reports/stage-2.md", [title: "Stage 2 test report"]},
        {"docs/test-reports/stage-3.md", [title: "Stage 3 test report"]},
        {"docs/test-reports/stage-4.md", [title: "Stage 4 test report"]},
        {"docs/test-reports/stage-5.md", [title: "Stage 5 test report"]}
      ]
    ]
  end

  defp before_closing_body_tag(:html) do
    Path.join(__DIR__, "docs/exdoc_mermaid.html") |> File.read!()
  end

  defp before_closing_body_tag(_format), do: ""
end
