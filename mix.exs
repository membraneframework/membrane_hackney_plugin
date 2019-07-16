defmodule Membrane.Element.Hackney.Mixfile do
  use Mix.Project

  @version "0.2.0"
  @github_url "http://github.com/membraneframework/membrane-element-hackney"

  def project do
    [
      app: :membrane_element_hackney,
      version: @version,
      elixir: "~> 1.7",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # hex
      description: "Membrane Multimedia Framework (Hackney Element)",
      package: package(),

      # docs
      name: "Membrane Element: Hackney",
      source_url: @github_url,
      docs: docs(),

      # others
      dialyzer: [flags: [:error_handling, :underspecs]]
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

  defp deps do
    [
      {:ex_doc, "~> 0.20", only: :dev, runtime: false},
      {:mockery, "~> 2.3", runtime: false},
      {:membrane_core, "~> 0.3.0"},
      {:dialyxir, "~> 1.0.0-rc.4", only: [:dev], runtime: false},
      {:hackney, "~> 1.15"}
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

  defp docs do
    [
      main: "readme",
      extras: ["README.md"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [
        Membrane.Element.Hackney
      ],
      before_closing_head_tag: &sidebar_fix/1
    ]
  end

  defp sidebar_fix(_) do
    """
    <style type="text/css">
    .sidebar div.sidebar-header {
      margin: 15px;
    }
    </style>
    """
  end
end
