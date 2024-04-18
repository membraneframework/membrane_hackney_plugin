# Membrane Hackney plugin

[![Hex.pm](https://img.shields.io/hexpm/v/membrane_hackney_plugin.svg)](https://hex.pm/packages/membrane_hackney_plugin)
[![API Docs](https://img.shields.io/badge/api-docs-yellow.svg?style=flat)](https://hexdocs.pm/membrane_hackney_plugin/)
[![CircleCI](https://circleci.com/gh/membraneframework/membrane_hackney_plugin.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane_hackney_plugin) 

HTTP sink and source based on the [Hackney](https://github.com/benoitc/hackney) library.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

Add the following line to your `deps` in `mix.exs`.  Run `mix deps.get`.

```elixir
	{:membrane_hackney_plugin, "~> 0.11.0"}
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
  def handle_init(_ctx, _opts) do
    spec = 
      child(:source, %Hackney.Source{
        location: "http://i.imgur.com/z4d4kWk.jpg",
        hackney_opts: [follow_redirect: true]
      })
      |> child(:sink, %File.Sink{location: "kitty.jpg"})

    {[spec: spec], %{}}
  end
end

{:ok, _supervisor_pid, _pipeline_pid} = Membrane.Pipeline.start_link(DownloadPipeline, [])
```

### Membrane.Hackney.Sink

The following pipeline is an example of file upload - it requires [Goth](https://github.com/peburrows/goth) library with
properly configured credentials for Google Cloud and [`:membrane_file_plugin`](https://github.com/membraneframework/membrane_file_plugin) in your project's dependencies.

```elixir
defmodule UploadPipeline do
  use Membrane.Pipeline

  alias Membrane.{File, Hackney}

  @impl true
  def handle_init(_ctx, [bucket, name]) do
    spec = 
      child(:source, %File.Source{location: "sample.flac"})
      |> child(:sink, %Hackney.Sink{
        method: :post,
        location: build_uri(bucket, name),
        headers: [auth_header(), {"content-type", "audio/flac"}]
      })

    {[spec: spec], %{}}
  end

  @impl true
  def handle_child_notification(%Hackney.Sink.Response{} = response, from, _ctx, state) do
    IO.inspect({from, response})
    {:ok, state}
  end

  @impl true
  def handle_child_notification(_notification, _from, _ctx, state) do
    {:ok, state}
  end

  defp auth_header() do
    {:ok, token} = Goth.Token.for_scope("https://www.googleapis.com/auth/devstorage.read_write")
    {"Authorization", "#{token.type} #{token.token}"}
  end

  defp build_uri(bucket, name) do
    "https://www.googleapis.com/upload/storage/v1/b/#{bucket}/o?" <>
      URI.encode_query(uploadType: "media", name: name)
  end
end

pipeline_opts = ["some_bucket", "uploaded_file_name.flac"]
{:ok, _supervisor_pid, _pipeline_pid} = Membrane.Pipeline.start_link(UploadPipeline, pipeline_opts)
```

## Sponsors

The development of this plugin was sponsored by [Abridge AI, Inc.](https://abridge.com)

## Copyright and License

Copyright 2018, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)
