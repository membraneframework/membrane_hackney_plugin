defmodule Membrane.Hackney.Source do
  @moduledoc """
  This module provides a source element allowing you to receive data as a client
  using HTTP. It is based upon [Hackney](https://github.com/benoitc/hackney)
  library that is responsible for making HTTP requests.

  See the `t:t/0` for the available configuration options.
  """
  use Membrane.Source

  import Mockery.Macro

  alias Membrane.{Buffer, Element, Time}

  require Membrane.Logger

  def_output_pad :output, caps: :any

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
  def handle_init(%__MODULE__{} = options) do
    state =
      options
      |> Map.merge(%{
        async_response: nil,
        retries: 0,
        streaming: false,
        pos_counter: 0
      })

    {:ok, state}
  end

  @impl true
  def handle_playing_to_prepared(_ctx, %{async_response: response} = state) do
    state =
      if response != nil do
        state |> close_request()
      else
        state
      end

    {:ok, %{state | retries: 0, pos_counter: 0}}
  end

  @impl true
  def handle_prepared_to_playing(_ctx, state) do
    state |> connect
  end

  @impl true
  def handle_demand(:output, _size, _unit, _ctx, %{streaming: true} = state) do
    # We have already requested next frame (using :hackney.stream_next())
    # so we do nothinig
    {:ok, state}
  end

  def handle_demand(:output, _size, _unit, _ctx, %{async_response: nil} = state) do
    # We're waiting for reconnect
    {:ok, state}
  end

  def handle_demand(:output, _size, _unit, _ctx, state) do
    Membrane.Logger.debug("Hackney: requesting next chunk")

    case state.async_response |> mockable(:hackney).stream_next() do
      :ok ->
        {:ok, %{state | streaming: true}}

      {:error, reason} ->
        Membrane.Logger.warn("Hackney.stream_next/1 error: #{inspect(reason)}")

        # Error here is rather caused by library error,
        # so we retry without delay - we will either sucessfully reconnect
        # or will get an error resulting in retry with delay
        retry({:stream_next, reason}, state |> close_request(), false)
    end
  end

  @impl true
  def handle_other({:hackney_response, msg_id, msg}, _ctx, %{async_response: id} = state)
      when msg_id != id do
    Membrane.Logger.warn(
      "Ignoring message #{inspect(msg)} because it does not match current response id: #{inspect(id)}"
    )

    {:ok, state}
  end

  def handle_other(
        {:hackney_response, id, {:status, code, desc}},
        _ctx,
        %{async_response: id} = state
      )
      when code in [200, 206] do
    Membrane.Logger.debug("Hackney: Got #{code} #{desc}")
    {{:ok, redemand: :output}, %{state | streaming: false, retries: 0}}
  end

  def handle_other(
        {:hackney_response, id, {:status, code, _data}},
        _ctx,
        %{async_response: id} = state
      )
      when code in [301, 302] do
    Membrane.Logger.warn("""
    Got #{inspect(code)} status indicating redirection.
    If you want to follow add `follow_redirect: true` to :poison_opts
    """)

    retry({:hackney, :redirect}, state |> close_request())
  end

  def handle_other(
        {:hackney_response, id, {:status, 416, _data}},
        _ctx,
        %{async_response: id} = state
      ) do
    Membrane.Logger.warn(
      "Hackney: Got 416 Invalid Range (pos_counter is #{inspect(state.pos_counter)})"
    )

    retry({:hackney, :invalid_range}, state |> close_request())
  end

  def handle_other(
        {:hackney_response, id, {:status, code, _data}},
        _ctx,
        %{async_response: id} = state
      ) do
    Membrane.Logger.warn("Hackney: Got unexpected status code #{code}")
    retry({:http_code, code}, state |> close_request())
  end

  def handle_other(
        {:hackney_response, id, {:headers, headers}},
        _ctx,
        %{async_response: id} = state
      ) do
    Membrane.Logger.debug("Hackney: Got headers #{inspect(headers)}")

    {{:ok, redemand: :output}, %{state | streaming: false}}
  end

  def handle_other(
        {:hackney_response, id, chunk},
        %Ctx.Other{playback_state: :playing},
        %{async_response: id} = state
      )
      when is_binary(chunk) do
    state =
      state
      |> Map.update!(:pos_counter, &(&1 + byte_size(chunk)))

    actions = [buffer: {:output, %Buffer{payload: chunk}}, redemand: :output]
    {{:ok, actions}, %{state | streaming: false}}
  end

  def handle_other({:hackney_response, id, chunk}, _ctx, %{async_response: id} = state)
      when is_binary(chunk) do
    # We received chunk after we've stopped playing. We'll ignore that data.
    {:ok, %{state | streaming: false}}
  end

  def handle_other({:hackney_response, id, :done}, _ctx, %{async_response: id} = state) do
    Membrane.Logger.info("Hackney EOS")
    new_state = %{state | streaming: false, async_response: nil}
    {{:ok, end_of_stream: :output}, new_state}
  end

  def handle_other({:hackney_response, id, {:error, reason}}, _ctx, %{async_response: id} = state) do
    Membrane.Logger.warn("Hackney error #{inspect(reason)}")

    retry({:hackney, reason}, state |> close_request())
  end

  def handle_other(
        {:hackney_response, id, {redirect, new_location, _headers}},
        _ctx,
        %{async_response: id} = state
      )
      when redirect in [:redirect, :see_other] do
    Membrane.Logger.debug("Hackney: redirecting to #{new_location}")

    %{state | location: new_location, streaming: false}
    |> close_request()
    |> connect
  end

  def handle_other(:reconnect, _ctx, state) do
    state |> connect()
  end

  @spec retry(reason :: any(), state :: Element.state_t(), delay? :: boolean) ::
          {:ok, Element.state_t()}
  defp retry(reason, state, delay? \\ true)

  defp retry(reason, %{retries: retries, max_retries: max_retries} = state, _delay)
       when retries >= max_retries do
    {{:error, reason}, state}
  end

  defp retry(_reason, state, false) do
    connect(%{state | retries: state.retries + 1})
  end

  defp retry(_reason, %{retry_delay: delay, retries: retries} = state, true) do
    Process.send_after(self(), :reconnect, delay |> Time.to_milliseconds())
    {:ok, %{state | retries: retries + 1}}
  end

  defp connect(state) do
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
        {:ok, %{state | async_response: async_response, streaming: true}}

      {:error, reason} ->
        Membrane.Logger.warn("""
        Error while making a request #{inspect({method, location, body, headers, opts})},
        reason #{inspect(reason)}
        """)

        retry({:hackney, reason}, state)
    end
  end

  defp close_request(%{async_response: nil} = state) do
    %{state | streaming: false}
  end

  defp close_request(%{async_response: resp} = state) do
    _result = mockable(:hackney).close(resp)
    %{state | async_response: nil, streaming: false}
  end
end
