# Membrane Hackney plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_hackney_plugin.svg)](https://hex.pm/packages/membrane_hackney_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_hackney_plugin/)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_hackney_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_hackney_plugin) 

HTTP sink and source based on the [Hackney](https://github.com/benoitc/hackney) library.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

Add the following line to your `deps` in `mix.exs`.  Run `mix deps.get`.

```elixir
  {:membrane_hackney_plugin, "~> 0.8.1"}
```

## Sample usage

### Membrane.Hackney.Source

This pipeline should get you a kitten from imgur and save as `kitty.jpg`. To run it you need 
[`:membrane_file_plugin`](https://github.com/membraneframework/membrane_file_plugin) in your project's dependencies.

```elixir
defmodule DownloadPipeline do
  use Membrane.Pipeline
  alias Membrane.{File, Hackney}

  @impl true
  def handle_init(_) do
    children = [
      source: %Hackney.Source{
        location: "http://i.imgur.com/z4d4kWk.jpg",
        hackney_opts: [follow_redirect: true]
      },
      sink: %File.Sink{location: "kitty.jpg"}
    ]

    links = [link(:source) |> to(:sink)]

    spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: spec}, %{}}
  end
end

{:ok, pid} = DownloadPipeline.start_link()
DownloadPipeline.play(pid)
```

### Membrane.Hackney.Sink

The following pipeline is an example of file upload - it requires [Goth](https://github.com/peburrows/goth) library with
properly configured credentials for Google Cloud and [`:membrane_file_plugin`](https://github.com/membraneframework/membrane_file_plugin) in your project's dependencies.

```elixir
defmodule UploadPipeline do
  use Membrane.Pipeline

  alias Membrane.{File, Hackney}

  @impl true
  def handle_init([bucket, name]) do
    children = [
      source: %File.Source{location: "sample.flac"},
      sink: %Hackney.Sink{
        method: :post,
        location: build_uri(bucket, name),
        headers: [auth_header(), {"content-type", "audio/flac"}]
      }
    ]

    links = [link(:source) |> to(:sink)]

    spec = %ParentSpec{children: children, links: links}

    {{:ok, spec: spec}, %{}}
  end

  @impl true
  def handle_notification(%Hackney.Sink.Response{} = response, from, _ctx, state) do
    IO.inspect({from, response})
    {:ok, state}
  end

  def handle_notification(_notification, _from, _ctx, state) do
    {:ok, state}
  end

  defp auth_header do
    {:ok, token} = Goth.Token.for_scope("https://www.googleapis.com/auth/devstorage.read_write")
    {"Authorization", "#{token.type} #{token.token}"}
  end

  defp build_uri(bucket, name) do
    "https://www.googleapis.com/upload/storage/v1/b/#{bucket}/o?" <>
      URI.encode_query(uploadType: "media", name: name)
  end
end

{:ok, pid} = UploadPipeline.start_link(["some_bucket", "uploaded_file_name.flac"])
UploadPipeline.play(pid)
```

## Sponsors

The development of this plugin was sponsored by [Abridge AI, Inc.](https://abridge.com)

## Copyright and License

Copyright 2018, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)
