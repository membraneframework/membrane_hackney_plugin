defmodule Membrane.Element.HTTPoison.SourceTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use Mockery
  alias Membrane.Element.CallbackContext, as: Ctx

  @module Membrane.Element.HTTPoison.Source

  @default_state %{
    body: "",
    headers: [],
    is_live: false,
    location: "url",
    method: :get,
    poison_opts: [],
    retries: 0,
    max_retries: 0,
    retry_delay: 1 |> Membrane.Time.millisecond(),
    async_response: nil,
    streaming: false,
    pos_counter: 0
  }

  @mock_response %HTTPoison.AsyncResponse{id: :ref}

  @ctx_other_pl %Ctx.Other{playback_state: :playing, pads: %{}}

  def state_streaming(_) do
    state =
      @default_state
      |> Map.merge(%{
        streaming: true,
        async_response: @mock_response
      })

    [state_streaming: state]
  end

  test "handle_playing_to_prepared/2 should close request when moving from :playing to :prepared" do
    state = %{@default_state | async_response: @mock_response}
    mock(:hackney, close: 1)
    assert {:ok, new_state} = @module.handle_playing_to_prepared(nil, state)
    assert new_state.async_response == nil
    assert_called(:hackney, :close, [:ref])
  end

  test "handle_stopped_to_prepared should do nothing" do
    mock(:hackney, close: 1)
    assert @module.handle_stopped_to_prepared(:stopped, @default_state) == {:ok, @default_state}
    refute_called(:hackney, :close)
  end

  test "handle_play/1 should start an async request" do
    mock(HTTPoison, [request: 5], {:ok, @mock_response})

    state =
      @default_state
      |> Map.merge(%{
        headers: [:hd],
        poison_opts: [opt: :some],
        body: "body"
      })

    assert {:ok, new_state} = @module.handle_prepared_to_playing(nil, state)
    assert new_state.async_response == @mock_response
    assert new_state.streaming == true

    assert_called(HTTPoison, :request, [
      :get,
      "url",
      "body",
      [:hd],
      [opt: :some, stream_to: _, async: :once]
    ])
  end

  describe "handle_demand/5 should" do
    test "request next chunk if it haven't been already" do
      state = %{@default_state | async_response: @mock_response}
      mock(HTTPoison, [stream_next: 1], {:ok, @mock_response})

      assert {:ok, new_state} = @module.handle_demand(:output, 42, :bytes, nil, state)
      assert new_state.async_response == @mock_response
      assert new_state.streaming == true

      pin_response = @mock_response

      assert_called(HTTPoison, :stream_next, [^pin_response])
    end

    test "return error when stream_next fails" do
      state = %{@default_state | async_response: @mock_response}
      mock(HTTPoison, [stream_next: 1], {:error, :reason})
      mock(:hackney, close: 1)

      assert {{:error, reason}, new_state} =
               @module.handle_demand(:output, 42, :bytes, nil, state)

      assert reason == {:stream_next, :reason}
      assert new_state.async_response == nil
      assert new_state.streaming == false

      pin_response = @mock_response

      assert_called(HTTPoison, :stream_next, [^pin_response])
      assert_called(:hackney, :close, [:ref])
    end

    test "do nothing when next chunk from HTTPoison was requested" do
      state = %{@default_state | streaming: true}
      mock(HTTPoison, [stream_next: 1], {:ok, @mock_response})

      assert @module.handle_demand(:output, 42, :bytes, nil, state) == {:ok, state}
      refute_called(HTTPoison, :stream_next)
    end
  end

  def test_msg_trigger_redemand(msg, state) do
    assert {{:ok, actions}, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
    assert actions == [redemand: :output]
    assert new_state.streaming == false
  end

  describe "handle_other/3 for message" do
    setup :state_streaming

    test "async status 200 should trigger redemand with streaming false", %{
      state_streaming: state
    } do
      msg = %HTTPoison.AsyncStatus{code: 200, id: :ref}
      test_msg_trigger_redemand(msg, state)
    end

    test "async status 206 should trigger redemand with streaming false", %{
      state_streaming: state
    } do
      msg = %HTTPoison.AsyncStatus{code: 206, id: :ref}
      test_msg_trigger_redemand(msg, state)
    end

    test "async status 301 should return error and close connection", %{state_streaming: state} do
      msg = %HTTPoison.AsyncStatus{code: 301, id: :ref}
      mock(:hackney, [close: 1], :ok)
      assert {{:error, reason}, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
      assert reason == {:httpoison, :redirect}
      assert new_state.streaming == false
      assert new_state.async_response == nil
      assert_called(:hackney, :close, [:ref])
    end

    test "async status 302 should should return error and close connection", %{
      state_streaming: state
    } do
      msg = %HTTPoison.AsyncStatus{code: 302, id: :ref}
      mock(:hackney, [close: 1], :ok)
      assert {{:error, reason}, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
      assert reason == {:httpoison, :redirect}
      assert new_state.streaming == false
      assert new_state.async_response == nil
      assert_called(:hackney, :close, [:ref])
    end

    test "async status 416 should should return error and close connection", %{
      state_streaming: state
    } do
      msg = %HTTPoison.AsyncStatus{code: 416, id: :ref}
      mock(:hackney, [close: 1], :ok)
      assert {{:error, reason}, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
      assert reason == {:httpoison, :invalid_range}
      assert new_state.streaming == false
      assert new_state.async_response == nil
      assert_called(:hackney, :close, [:ref])
    end

    test "async status with unsupported code should return error and close connection", %{
      state_streaming: state
    } do
      mock(:hackney, [close: 1], :ok)
      codes = [500, 501, 502, 402, 404]

      codes
      |> Enum.each(fn code ->
        msg = %HTTPoison.AsyncStatus{code: code, id: :ref}
        assert {{:error, reason}, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
        assert reason == {:http_code, code}
        assert new_state.streaming == false
        assert new_state.async_response == nil
      end)

      assert_called(:hackney, :close, [:ref], [length(codes)])
    end

    test "async headers should trigger redemand with streaming false", %{state_streaming: state} do
      msg = %HTTPoison.AsyncHeaders{headers: [], id: :ref}
      test_msg_trigger_redemand(msg, state)
    end

    test "async chunk when not playing should ignore the data", %{state_streaming: state} do
      msg = %HTTPoison.AsyncChunk{chunk: <<>>, id: :ref}
      ctx = %Ctx.Other{playback_state: :prepared, pads: %{}}
      assert {:ok, new_state} = @module.handle_other(msg, ctx, state)
      assert new_state.streaming == false
    end

    test "async chunk should produce buffer, update pos_counter and trigger redemand", %{
      state_streaming: state
    } do
      msg = %HTTPoison.AsyncChunk{chunk: <<1, 2, 3>>, id: :ref}
      assert {{:ok, actions}, new_state} = @module.handle_other(msg, @ctx_other_pl, state)

      assert [buffer: buf_action, redemand: :output] = actions
      assert buf_action == {:output, %Membrane.Buffer{payload: <<1, 2, 3>>}}

      assert new_state.pos_counter == state.pos_counter + 3
      assert new_state.streaming == false
    end

    test "async end should send EOS event and remove asyn_response from state", %{
      state_streaming: state
    } do
      msg = %HTTPoison.AsyncEnd{id: :ref}
      assert {{:ok, actions}, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
      assert actions == [event: {:output, %Membrane.Event.EndOfStream{}}]
      assert new_state.async_response == nil
      assert new_state.streaming == false
    end

    test "HTTPoison error should return error and close request", %{state_streaming: state} do
      mock(:hackney, [close: 1], :ok)
      msg = %HTTPoison.Error{reason: :reason, id: :ref}
      assert {{:error, reason}, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
      assert reason == {:httpoison, :reason}
      assert new_state.streaming == false
      assert new_state.async_response == nil
      assert_called(:hackney, :close, [:ref])
    end

    test "async redirect should change location and start create new request", %{
      state_streaming: state
    } do
      second_response = %HTTPoison.AsyncResponse{id: :ref2}
      mock(HTTPoison, [request: 5], {:ok, second_response})

      state =
        state
        |> Map.merge(%{
          headers: [:hd],
          poison_opts: [opt: :some],
          body: "body"
        })

      msg = %HTTPoison.AsyncRedirect{to: "url2", id: :ref}
      assert {:ok, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
      assert new_state.location == "url2"
      assert new_state.async_response == second_response
      assert new_state.streaming == true

      assert_called(HTTPoison, :request, [
        :get,
        "url2",
        "body",
        [:hd],
        [opt: :some, stream_to: _, async: :once]
      ])
    end
  end

  def state_resume_not_live(_) do
    state =
      @default_state
      |> Map.merge(%{
        max_retries: 1,
        async_response: @mock_response,
        pos_counter: 42
      })

    second_response = %HTTPoison.AsyncResponse{id: :ref2}
    expected_headers = [{"Range", "bytes=42-"}]
    [state: state, second_response: second_response, expected_headers: expected_headers]
  end

  def test_reconnect(ctx, tested_call) do
    %{
      second_response: second_response,
      state: state,
      expected_headers: expected_headers
    } = ctx

    mock(:hackney, [close: 1], :ok)
    mock(HTTPoison, [request: 5], {:ok, ctx.second_response})

    assert {:ok, new_state} = tested_call.(state)
    assert new_state.async_response == second_response
    assert new_state.streaming == true

    assert_called(HTTPoison, :request, [
      :get,
      "url",
      "",
      ^expected_headers,
      [stream_to: _, async: :once]
    ])

    assert_called(:hackney, :close, [:ref])
  end

  describe "with max_retries = 1 in options" do
    setup :state_resume_not_live

    test "handle_demand should reconnect on error starting from current position", ctx do
      mock(HTTPoison, [stream_next: 1], {:error, :reason})

      test_reconnect(ctx, fn state ->
        @module.handle_demand(:output, 42, :bytes, nil, state)
      end)

      # trick to overcome Mockery limitations
      pin_response = @mock_response
      assert_called(HTTPoison, :stream_next, [^pin_response])
    end

    test "handle_other should send :reconnect on error", %{state: state} do
      msg = %HTTPoison.Error{reason: :reason, id: :ref}
      mock(:hackney, [close: 1], :ok)
      assert {:ok, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
      assert new_state.retries == state.retries + 1
      assert_receive :reconnect
    end
  end

  def state_resume_live(_) do
    state =
      @default_state
      |> Map.merge(%{
        max_retries: 1,
        is_live: true,
        async_response: @mock_response,
        pos_counter: 42
      })

    second_response = %HTTPoison.AsyncResponse{id: :ref2}
    [state: state, second_response: second_response, expected_headers: []]
  end

  describe "with max_retries = 1 and is_live: true in options" do
    setup :state_resume_live

    test "handle_demand should reconnect on error", ctx do
      mock(HTTPoison, [stream_next: 1], {:error, :reason})

      test_reconnect(ctx, fn state ->
        @module.handle_demand(:output, 42, :bytes, nil, state)
      end)

      # trick to overcome Mockery limitations
      pin_response = @mock_response
      assert_called(HTTPoison, :stream_next, [^pin_response])
    end

    test "handle_other", %{state: state} do
      msg = %HTTPoison.Error{reason: :reason, id: :ref}
      mock(:hackney, [close: 1], :ok)
      assert {:ok, new_state} = @module.handle_other(msg, @ctx_other_pl, state)
      assert new_state.retries == state.retries + 1
      assert_receive :reconnect
    end
  end
end
