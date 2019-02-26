# Membrane Multimedia Framework: Hackney Element

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_element_hackney.svg)](https://hex.pm/packages/membrane_element_hackney)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_element_hackney/)
[![Build Status](https://travis-ci.com/membraneframework/membrane-element-hackney.svg?branch=master)](https://travis-ci.com/membraneframework/membrane-element-hackney)

This package provides elements that can be used to read files over HTTP using
[Hackney](https://github.com/benoitc/hackney) library.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

Add the following line to your `deps` in `mix.exs`.  Run `mix deps.get`.

```elixir
{:membrane_element_hackney, "~> 0.1"}
```

## Sample usage

This should get you a kitten from imgur and save as `kitty.jpg`.

```elixir
defmodule Hackney.Pipeline do
  use Membrane.Pipeline
  alias Pipeline.Spec
  alias Membrane.Element.File
  alias Membrane.Element.Hackney

  @impl true
  def handle_init(_) do
    children = [
      hackney_src: %Hackney.Source{location: "http://i.imgur.com/z4d4kWk.jpg"},
      file_sink: %File.Sink{location: "kitty.jpg"},
    ]
    links = %{
      {:hackney_src, :source} => {:file_sink, :sink}
    }

    {{:ok, %Spec{children: children, links: links}}, %{}}
  end
end
```

## Copyright and License

Copyright 2018, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)

[![Software Mansion](https://membraneframework.github.io/static/logo/swm_logo_readme.png)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)
