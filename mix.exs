defmodule Membrane.Hackney.Plugin.Mixfile do
  use Mix.Project

  @version "0.4.0"
  @github_url "http://github.com/membraneframework/membrane_hackney_plugin"

  def project do
    [
      app: :membrane_hackney_plugin,
      version: @version,
      elixir: "~> 1.10",
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # hex
      description: "HTTP sink/source based on hackney",
      package: package(),

      # docs
      name: "Membrane Hackney plugin",
      source_url: @github_url,
      docs: docs(),

      # others
      dialyzer: [flags: [:error_handling, :underspecs]]
    ]
  end

  def application do
    [
      extra_applications: []
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "spec/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 0.6.0"},
      {:ex_doc, "~> 0.21", only: :dev, runtime: false},
      {:mockery, "~> 2.3", runtime: false},
      {:dialyxir, "~> 1.0.0-rc.7", only: [:dev], runtime: false},
      {:credo, "~> 1.4", only: :dev, runtime: false},
      {:hackney, "~> 1.16"}
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
        Membrane.Hackney
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
