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

  @resource_tag :hackney_source_resource

  def_output_pad :output,
    accepted_format: %RemoteStream{type: :bytestream, content_format: nil},
    flow_control: :manual

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

  @impl true
  def handle_init(_ctx, %__MODULE__{} = options) do
    state =
      options
      |> Map.merge(%{
        async_response: nil,
        conn_monitor: nil,
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

  def handle_demand(:output, _size, _unit, _ctx, state) do
    Membrane.Logger.debug_verbose("Hackney: requesting next chunk")
    state.async_response |> mockable(:hackney).stream_next()
    {[], %{state | streaming: true}}
  end

  @impl true
  def handle_info({:hackney_response, msg_id, msg}, _ctx, %{async_response: id} = state)
      when msg_id != id do
    Membrane.Logger.warning(
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
    Membrane.Logger.debug_verbose("Hackney: Got #{code} #{desc}")
    {[redemand: :output], %{state | streaming: false, retries: 0}}
  end

  def handle_info(
        {:hackney_response, id, {:status, code, _data}},
        ctx,
        %{async_response: id} = state
      )
      when code in [301, 302] do
    Membrane.Logger.warning("""
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
    Membrane.Logger.warning(
      "Hackney: Got 416 Invalid Range (pos_counter is #{inspect(state.pos_counter)})"
    )

    retry({:hackney, :invalid_range}, ctx, close_request(ctx, state))
  end

  def handle_info(
        {:hackney_response, id, {:status, code, _data}},
        ctx,
        %{async_response: id} = state
      ) do
    Membrane.Logger.warning("Hackney: Got unexpected status code #{code}")
    retry({:http_code, code}, ctx, close_request(ctx, state))
  end

  def handle_info(
        {:hackney_response, id, {:headers, headers}},
        _ctx,
        %{async_response: id} = state
      ) do
    Membrane.Logger.debug_verbose("Hackney: Got headers #{inspect(headers)}")

    {[redemand: :output], %{state | streaming: false}}
  end

  def handle_info(
        {:hackney_response, id, chunk},
        %{playback: :playing},
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
    new_state = %{demonitor_conn(state) | streaming: false, async_response: nil}
    {[end_of_stream: :output], new_state}
  end

  def handle_info({:hackney_response, id, {:error, reason}}, ctx, %{async_response: id} = state) do
    Membrane.Logger.warning("Hackney error #{inspect(reason)}")

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

  def handle_info({:DOWN, monitor, :process, _pid, reason}, ctx, %{conn_monitor: monitor} = state) do
    Membrane.Logger.warning("Hackney connection process died, reason: #{inspect(reason)}")
    Membrane.ResourceGuard.unregister(ctx.resource_guard, @resource_tag)
    state = %{state | async_response: nil, conn_monitor: nil, streaming: false}

    # Death of the connection process is rather caused by a library error,
    # so we retry without delay - we will either successfully reconnect
    # or get an error resulting in a retry with delay
    retry({:hackney, {:connection_down, reason}}, ctx, state, false)
  end

  def handle_info({:DOWN, _monitor, :process, _pid, _reason}, _ctx, state) do
    {[], state}
  end

  def handle_info(:reconnect, ctx, state) do
    connect(ctx, state)
  end

  defp retry(reason, ctx, state, delay? \\ true)

  defp retry(reason, _ctx, %{retries: retries, max_retries: max_retries}, _delay?)
       when retries >= max_retries do
    raise "Error: Max retries number reached. Retry reason: #{inspect(reason)}"
  end

  defp retry(_reason, ctx, state, _delay? = false) do
    connect(ctx, %{state | retries: state.retries + 1})
  end

  defp retry(_reason, _ctx, %{retry_delay: delay, retries: retries} = state, _delay? = true) do
    Process.send_after(self(), :reconnect, Time.as_milliseconds(delay, :round))
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

        # The connection never notifies us if it dies before delivering
        # a response message, so we need to monitor it ourselves
        conn_monitor = Process.monitor(async_response)

        {[],
         %{state | async_response: async_response, conn_monitor: conn_monitor, streaming: true}}

      {:error, reason} ->
        Membrane.Logger.warning("""
        Error while making a request #{inspect({method, location, body, headers, opts})},
        reason #{inspect(reason)}
        """)

        retry({:hackney, reason}, ctx, state)
    end
  end

  defp close_request(_ctx, %{async_response: nil} = state) do
    %{state | streaming: false}
  end

  defp close_request(ctx, state) do
    Membrane.ResourceGuard.cleanup(ctx.resource_guard, @resource_tag)
    %{demonitor_conn(state) | async_response: nil, streaming: false}
  end

  defp demonitor_conn(%{conn_monitor: nil} = state), do: state

  defp demonitor_conn(state) do
    Process.demonitor(state.conn_monitor, [:flush])
    %{state | conn_monitor: nil}
  end
end
