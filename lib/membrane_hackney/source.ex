defmodule Membrane.Hackney.Source do
  @moduledoc """
  This module provides a source element allowing you to receive data as a client
  using HTTP. It is based upon [Hackney](https://github.com/benoitc/hackney)
  library that is responsible for making HTTP requests.

  See the `t:t/0` for the available configuration options.
  """
  use Membrane.Source

  import Mockery.Macro

  require Membrane.Logger
  alias Membrane.{Buffer, RemoteStream, Time}

  @resource_tag :hackney_soruce_resource

  def_output_pad :output,
    accepted_format: %RemoteStream{type: :bytestream, content_format: nil}

  def_options location: [
                type: :string,
                description: "The URL to fetch by the element"
              ],
              method: [
                type: :atom,
                spec: :get | :post | :put | :patch | :delete | :head | :options,
                description: "HTTP method that will be used when making a request",
                default: :get
              ],
              body: [
                type: :string,
                description: "The request body",
                default: ""
              ],
              headers: [
                type: :keyword,
                description:
                  "List of additional request headers in format accepted by `:hackney.request/5`",
                default: []
              ],
              hackney_opts: [
                type: :keyword,
                description:
                  "Additional options for Hackney in format accepted by `:hackney.request/5`",
                default: []
              ],
              max_retries: [
                type: :integer,
                spec: non_neg_integer() | :infinity,
                description: """
                Maximum number of retries before returning an error. Can be set to `:infinity`.
                """,
                default: 0
              ],
              retry_delay: [
                type: :time,
                description: """
                Delay between reconnection attempts in case of connection error.
                """,
                default: Time.second()
              ],
              is_live: [
                type: :boolean,
                description: """
                Assume the source is live. If true, when resuming after error,
                the element will not use `Range` header to skip to the
                current position in bytes.
                """,
                default: false
              ]

  @spec get_resource_tag() :: atom()
  def get_resource_tag(), do: @resource_tag

  @impl true
  def handle_init(_ctx, %__MODULE__{} = options) do
    state =
      options
      |> Map.merge(%{
        async_response: nil,
        retries: 0,
        streaming: false,
        pos_counter: 0
      })

    {[], state}
  end

  @impl true
  def handle_playing(ctx, state) do
    {actions, state} = connect(ctx, state)
    actions = actions ++ [stream_format: {:output, %RemoteStream{type: :bytestream}}]
    {actions, state}
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, %{streaming: true} = state) do
    # We have already requested next frame (using :hackney.stream_next())
    # so we do nothinig
    {[], state}
  end

  def handle_demand(:output, _size, _unit, _ctx, %{async_response: nil} = state) do
    # We're waiting for reconnect
    {[], state}
  end

  def handle_demand(:output, _size, _unit, ctx, state) do
    Membrane.Logger.debug("Hackney: requesting next chunk")

    case state.async_response |> mockable(:hackney).stream_next() do
      :ok ->
        {[], %{state | streaming: true}}

      {:error, reason} ->
        Membrane.Logger.warn("Hackney.stream_next/1 error: #{inspect(reason)}")

        # Error here is rather caused by library error,
        # so we retry without delay - we will either sucessfully reconnect
        # or will get an error resulting in retry with delay
        retry({:stream_next, reason}, ctx, close_request(ctx, state), false)
    end
  end

  @impl true
  def handle_info({:hackney_response, msg_id, msg}, _ctx, %{async_response: id} = state)
      when msg_id != id do
    Membrane.Logger.warn(
      "Ignoring message #{inspect(msg)} because it does not match current response id: #{inspect(id)}"
    )

    {[], state}
  end

  def handle_info(
        {:hackney_response, id, {:status, code, desc}},
        _ctx,
        %{async_response: id} = state
      )
      when code in [200, 206] do
    Membrane.Logger.debug("Hackney: Got #{code} #{desc}")
    {[redemand: :output], %{state | streaming: false, retries: 0}}
  end

  def handle_info(
        {:hackney_response, id, {:status, code, _data}},
        ctx,
        %{async_response: id} = state
      )
      when code in [301, 302] do
    Membrane.Logger.warn("""
    Got #{inspect(code)} status indicating redirection.
    If you want to follow add `follow_redirect: true` to :poison_opts
    """)

    retry({:hackney, :redirect}, ctx, close_request(ctx, state))
  end

  def handle_info(
        {:hackney_response, id, {:status, 416, _data}},
        ctx,
        %{async_response: id} = state
      ) do
    Membrane.Logger.warn(
      "Hackney: Got 416 Invalid Range (pos_counter is #{inspect(state.pos_counter)})"
    )

    retry({:hackney, :invalid_range}, ctx, close_request(ctx, state))
  end

  def handle_info(
        {:hackney_response, id, {:status, code, _data}},
        ctx,
        %{async_response: id} = state
      ) do
    Membrane.Logger.warn("Hackney: Got unexpected status code #{code}")
    retry({:http_code, code}, ctx, close_request(ctx, state))
  end

  def handle_info(
        {:hackney_response, id, {:headers, headers}},
        _ctx,
        %{async_response: id} = state
      ) do
    Membrane.Logger.debug("Hackney: Got headers #{inspect(headers)}")

    {[redemand: :output], %{state | streaming: false}}
  end

  def handle_info(
        {:hackney_response, id, chunk},
        %Ctx.Info{playback: :playing},
        %{async_response: id} = state
      )
      when is_binary(chunk) do
    state =
      state
      |> Map.update!(:pos_counter, &(&1 + byte_size(chunk)))

    actions = [buffer: {:output, %Buffer{payload: chunk}}, redemand: :output]
    {actions, %{state | streaming: false}}
  end

  def handle_info({:hackney_response, id, chunk}, _ctx, %{async_response: id} = state)
      when is_binary(chunk) do
    # We received chunk after we've stopped playing. We'll ignore that data.
    {[], %{state | streaming: false}}
  end

  def handle_info({:hackney_response, id, :done}, _ctx, %{async_response: id} = state) do
    Membrane.Logger.info("Hackney EOS")
    new_state = %{state | streaming: false, async_response: nil}
    {[end_of_stream: :output], new_state}
  end

  def handle_info({:hackney_response, id, {:error, reason}}, ctx, %{async_response: id} = state) do
    Membrane.Logger.warn("Hackney error #{inspect(reason)}")

    retry({:hackney, reason}, ctx, close_request(ctx, state))
  end

  def handle_info(
        {:hackney_response, id, {redirect, new_location, _headers}},
        ctx,
        %{async_response: id} = state
      )
      when redirect in [:redirect, :see_other] do
    Membrane.Logger.debug("Hackney: redirecting to #{new_location}")

    state = %{state | location: new_location, streaming: false}
    state = close_request(ctx, state)
    connect(ctx, state)
  end

  def handle_info(:reconnect, ctx, state) do
    connect(ctx, state)
  end

  defp retry(reason, ctx, state, delay? \\ true)

  defp retry(reason, _ctx, %{retries: retries, max_retries: max_retries}, _delay)
       when retries >= max_retries do
    raise "Error: Max retries number reached. Retry reason: #{inspect(reason)}"
  end

  defp retry(_reason, ctx, state, false) do
    connect(ctx, %{state | retries: state.retries + 1})
  end

  defp retry(_reason, _ctx, %{retry_delay: delay, retries: retries} = state, true) do
    delay_miliseconds = Time.round_to_timebase(delay, Time.millisecond())
    Process.send_after(self(), :reconnect, delay_miliseconds)
    {[], %{state | retries: retries + 1}}
  end

  defp connect(ctx, state) do
    %{
      method: method,
      location: location,
      body: body,
      headers: headers,
      hackney_opts: opts,
      pos_counter: pos,
      is_live: is_live
    } = state

    opts = opts |> Keyword.merge(stream_to: self(), async: :once)

    headers =
      if pos > 0 and not is_live do
        [{"Range", "bytes=#{pos}-"} | headers]
      else
        headers
      end

    Membrane.Logger.debug(
      "Hackney: connecting, request: #{inspect({method, location, body, headers, opts})}"
    )

    case mockable(:hackney).request(method, location, headers, body, opts) do
      {:ok, async_response} ->
        Membrane.ResourceGuard.register(
          ctx.resource_guard,
          fn -> mockable(:hackney).close(async_response) end,
          tag: @resource_tag
        )

        {[], %{state | async_response: async_response, streaming: true}}

      {:error, reason} ->
        Membrane.Logger.warn("""
        Error while making a request #{inspect({method, location, body, headers, opts})},
        reason #{inspect(reason)}
        """)

        retry({:haceney, reason}, ctx, state)
    end
  end

  defp close_request(_ctx, %{async_response: nil} = state) do
    %{state | streaming: false}
  end

  defp close_request(ctx, state) do
    Membrane.ResourceGuard.cleanup(ctx.resource_guard, @resource_tag)
    %{state | async_response: nil, streaming: false}
  end

  # defp register_resource(ctx, resource) do
  #   Membrane.ResourceGuard.register(
  #     ctx.resource_guard,
  #     fn -> mockable(:hackney).close(resource) end,
  #     name: @resource_name
  #   )
  # end

  # defp cleanup_resource(ctx) do
  #   Membrane.ResourceGuard.cleanup(ctx.resource_guard, @resource_name)
  # end
end
