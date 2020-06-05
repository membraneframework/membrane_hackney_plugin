# Membrane Multimedia Framework: Hackney Element

[![CircleCI](https://circleci.com/gh/membraneframework/membrane-element-hackney.svg?style=svg)](https://circleci.com/gh/membraneframework/membrane-element-hackney) 

This package provides elements that can be used to read files over HTTP using
[Hackney](https://github.com/benoitc/hackney) library.

It is part of [Membrane Multimedia Framework](https://membraneframework.org).

## Installation

Add the following line to your `deps` in `mix.exs`.  Run `mix deps.get`.

```elixir
{:membrane_element_hackney, "~> 0.3"}
```

## Sample usage

### `Membrane.Element.Hackney.Source`

This pipeline should get you a kitten from imgur and save as `kitty.jpg`. To run it you need [`:membrane_element_file`](https://github.com/membraneframework/membrane-element-file) in your project's dependencies.

```elixir
defmodule DownloadPipeline do
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

{:ok, pid} = DownloadPipeline.start(nil)
DownloadPipeline.play(pid)
```

### `Membrane.Element.Hackney.Sink`

The following pipeline is an example of file upload - it requires [Goth](https://github.com/peburrows/goth) library with
properly configurated credentials for Google Cloud and [`:membrane_element_file`](https://github.com/membraneframework/membrane-element-file)

```elixir
defmodule UploadPipeline do
  use Membrane.Pipeline

  alias Membrane.Pipeline.Spec
  alias Membrane.Element.{File, Hackney}

  @impl true
  def handle_init([bucket, name]) do
    children = [
      src: %File.Source{location: "sample.flac"},
      sink: %Hackney.Sink{
        method: :post,
        location: build_uri(bucket, name),
        headers: [auth_header(), {"content-type", "audio/flac"}]
      }
    ]

    links = %{
      {:src, :output} => {:sink, :input}
    }

    {{:ok, %Spec{children: children, links: links}}, %{}}
  end

  @impl true
  def handle_notification(%Hackney.Sink.Response{} = response, element_name, state) do
    IO.inspect({element_name, response})
    {:ok, state}
  end

  def handle_notification(_notification, _element_name, state) do
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

{:ok, pid} = UploadPipeline.start(["some_bucket", "uploaded_file_name.flac"])
UploadPipeline.play(pid)
```

## Sponsors

The development of this element was sponsored by [Abridge AI, Inc.](https://abridge.com)

## Copyright and License

Copyright 2018, [Software Mansion](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)

[![Software Mansion](https://logo.swmansion.com/logo?color=white&variant=desktop&width=200&tag=membrane-github)](https://swmansion.com/?utm_source=git&utm_medium=readme&utm_campaign=membrane)
