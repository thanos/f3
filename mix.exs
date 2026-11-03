defmodule F3.MixProject do
  use Mix.Project

  @version "0.0.1"
  @upstream "https://github.com/future-file-format/F3"
  @paper "https://doi.org/10.1145/3749163"

  def project do
    [
      app: :f3,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      docs: docs(),
      name: "F3",
      homepage_url: @paper
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:rustler, "~> 0.38.0", optional: true},
      {:ex_doc, "~> 0.38", only: :dev, runtime: false}
    ]
  end

  defp description do
    """
    Experimental Elixir library for the F3 columnar file format.
    Reading and writing row data are not implemented. Upstream F3 is a research prototype.
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
        {"docs/tutorials/publication-plan.md", [title: "Publication plan"]},
        {"docs/test-reports/stage-0.md", [title: "Stage 0 test report"]}
      ]
    ]
  end
end
