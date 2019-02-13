defmodule Membrane.Element.Hackney.Mixfile do
  use Mix.Project

  @version "0.1.0"
  @github_url "http://github.com/membraneframework/membrane-element-hackney"

  def project do
    [
      app: :membrane_element_hackney,
      compilers: Mix.compilers(),
      version: @version,
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      description: "Membrane Multimedia Framework (Hackney Element)",
      package: package(),
      name: "Membrane Element: Hackney",
      source_url: @github_url,
      docs: docs(),
      deps: deps()
    ]
  end

  def application do
    [
      extra_applications: [],
      mod: {Membrane.Element.Hackney, []}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "spec/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}"
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache 2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp deps do
    [
      {:ex_doc, "~> 0.19", only: :dev, runtime: false},
      {:mockery, "~> 2.1", runtime: false},
      {:membrane_core, "~> 0.2.0"},
      {:hackney, "~> 1.15"}
    ]
  end
end
