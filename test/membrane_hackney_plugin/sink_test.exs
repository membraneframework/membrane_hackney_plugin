defmodule Membrane.Element.Hackney.SinkTest do
  use ExUnit.Case, async: true
  use Mockery

  alias Membrane.Buffer

  @module Membrane.Hackney.Sink

  @mock_url "http://some_url.com/upload"
  @mock_conn_ref :conn_ref
  @mock_payload "payload!"

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

  test "Initialization" do
    assert @module.handle_init(%@module{location: @mock_url}) == {:ok, initial_state()}
  end

  test "Moving to playing state" do
    mock(:hackney, [request: 5], {:ok, @mock_conn_ref})

    assert {{:ok, action}, new_state} = @module.handle_prepared_to_playing(%{}, initial_state())

    assert [demand: {:input, demand}] = action
    assert demand > 0

    assert new_state.conn_ref == @mock_conn_ref
  end

  test "Leaving playing state" do
    mock(:hackney, close: 1)

    assert @module.handle_playing_to_prepared(%{}, playing_state()) == {:ok, initial_state()}
    conn_ref = @mock_conn_ref
    assert_called(:hackney, :close, [^conn_ref])
  end

  test "handling incoming buffers" do
    mock(:hackney, send_body: 2)

    state = playing_state()

    assert {{:ok, action}, ^state} =
             @module.handle_write(:input, %Buffer{payload: @mock_payload}, %{}, state)

    assert [demand: {:input, demand}] = action
    assert demand > 0

    conn_ref = @mock_conn_ref
    payload = @mock_payload
    assert_called(:hackney, :send_body, [^conn_ref, ^payload])
  end

  describe "event handling:" do
    test "EndOfStream" do
      status = 200
      headers = []
      body = "body"
      state = playing_state()

      mock(:hackney, [start_response: 1], {:ok, status, headers, @mock_conn_ref})
      mock(:hackney, [body: 1], {:ok, body})

      assert {{:ok, actions}, ^state} = @module.handle_end_of_stream(:input, %{}, state)

      assert [response, eos] = actions |> Keyword.get_values(:notify)
      assert response == %@module.Response{status: status, headers: headers, body: body}
      assert eos == {:end_of_stream, :input}
    end

    test "others" do
      mock_event = :event
      state = playing_state()
      assert {:ok, state} = @module.handle_event(:input, mock_event, %{}, state)
    end
  end
end
