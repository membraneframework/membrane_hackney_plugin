defmodule Membrane.Hackney.Plugin.Mixfile do
  use Mix.Project

  @version "0.8.2"
  @github_url "http://github.com/membraneframework/membrane_hackney_plugin"

  def project do
    [
      app: :membrane_hackney_plugin,
      version: @version,
      elixir: "~> 1.12",
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
  defp elixirc_paths(_env), do: ["lib"]

  defp deps do
    [
      {:membrane_core, "~> 0.10.0"},
      {:hackney, "~> 1.16"},
      {:mockery, "~> 2.3", runtime: false},
      {:ex_doc, "~> 0.28", only: :dev, runtime: false},
      {:dialyxir, "~> 1.1", only: :dev, runtime: false},
      {:credo, "~> 1.6", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      maintainers: ["Membrane Team"],
      licenses: ["Apache-2.0"],
      links: %{
        "GitHub" => @github_url,
        "Membrane Framework Homepage" => "https://membraneframework.org"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", LICENSE: [title: "License"]],
      formatters: ["html"],
      source_ref: "v#{@version}",
      nest_modules_by_prefix: [
        Membrane.Hackney
      ]
    ]
  end
end
