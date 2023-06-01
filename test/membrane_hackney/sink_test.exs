defmodule Membrane.Element.Hackney.SinkTest do
  use ExUnit.Case, async: true
  use Mockery

  import Membrane.Testing.Assertions

  alias Membrane.Buffer
  alias Membrane.Testing.MockResourceGuard

  @module Membrane.Hackney.Sink

  @mock_url "http://some_url.com/upload"
  @mock_conn_ref :conn_ref
  @mock_payload "payload!"

  defp get_contexts(_params) do
    {:ok, resource_guard} = MockResourceGuard.start_link()

    ctx = %{
      playback: :playing,
      pads: %{},
      clock: nil,
      parent_clock: nil,
      resource_guard: resource_guard,
      utility_supervisor: :mock_utility_supervisor,
      name: :source
    }

    [
      ctx_write: ctx,
      ctx_playing: ctx,
      ctx_init: ctx,
      ctx_end_of_stream: ctx,
      ctx_event: ctx
    ]
  end

  setup :get_contexts

  defp initial_state do
    %{
      location: @mock_url,
      method: :post,
      headers: [],
      hackney_opts: [],
      demand_size: 1024,
      conn_ref: nil
    }
  end

  defp playing_state do
    %{initial_state() | conn_ref: @mock_conn_ref}
  end

  test "Initialization", %{ctx_init: ctx} do
    assert @module.handle_init(ctx, %@module{location: @mock_url}) == {[], initial_state()}
  end

  test "Moving to playing state", %{ctx_playing: ctx} do
    mock(:hackney, [request: 5], {:ok, @mock_conn_ref})
    mock(:hackney, close: 1)

    assert {actions, new_state} = @module.handle_playing(ctx, initial_state())

    assert [demand: {:input, demand}] = actions
    assert demand > 0

    assert new_state.conn_ref == @mock_conn_ref

    assert_resource_guard_register(
      ctx.resource_guard,
      cleanup_function,
      {:conn_ref, @mock_conn_ref}
    )

    refute_called(:hackeny, :close)

    cleanup_function.()

    assert_called(:hackney, :close, [@mock_conn_ref])
  end

  test "handling incoming buffers", %{ctx_write: ctx} do
    mock(:hackney, send_body: 2)

    state = playing_state()

    assert {actions, ^state} =
             @module.handle_write(:input, %Buffer{payload: @mock_payload}, ctx, state)

    assert [demand: {:input, demand}] = actions
    assert demand > 0

    conn_ref = @mock_conn_ref
    payload = @mock_payload
    assert_called(:hackney, :send_body, [^conn_ref, ^payload])
  end

  describe "event handling:" do
    test "EndOfStream", %{ctx_end_of_stream: ctx} do
      status = 200
      headers = []
      body = "body"
      state = playing_state()

      mock(:hackney, [start_response: 1], {:ok, status, headers, @mock_conn_ref})
      mock(:hackney, [body: 1], {:ok, body})

      assert {actions, ^state} = @module.handle_end_of_stream(:input, ctx, state)

      assert [response] = actions |> Keyword.get_values(:notify_parent)
      assert response == %@module.Response{status: status, headers: headers, body: body}
    end

    test "others", %{ctx_event: ctx} do
      mock_event = :event
      state = playing_state()
      assert @module.handle_event(:input, mock_event, ctx, state) == {[], state}
    end
  end
end
