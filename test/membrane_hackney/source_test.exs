defmodule Membrane.Hackney.SourceTest do
  @moduledoc false
  use ExUnit.Case, async: true
  use Mockery

  import Membrane.Testing.Assertions

  alias Membrane.Element.CallbackContext, as: Ctx
  alias Membrane.RemoteStream
  alias Membrane.Testing.MockResourceGuard

  @module Membrane.Hackney.Source

  @default_state %{
    body: "",
    headers: [],
    is_live: false,
    location: "url",
    method: :get,
    hackney_opts: [],
    retries: 0,
    max_retries: 0,
    retry_delay: Membrane.Time.millisecond(),
    async_response: nil,
    streaming: false,
    pos_counter: 0
  }

  defp get_contexts(_params \\ nil) do
    {:ok, resource_guard} = MockResourceGuard.start_link()

    ctx_fields = [
      playback: :playing,
      pads: %{},
      clock: nil,
      parent_clock: nil,
      resource_guard: resource_guard,
      utility_supervisor: :mock_utility_supervisor,
      name: :source
    ]

    [
      ctx_info: struct!(Ctx.Info, ctx_fields),
      ctx_playing: struct!(Ctx.Playing, ctx_fields),
      ctx_demand: struct!(Ctx.Demand, [incoming_demand: 1] ++ ctx_fields)
    ]
  end

  defp state_streaming(_params) do
    state =
      @default_state
      |> Map.merge(%{
        streaming: true,
        async_response: :mock_response
      })

    [state_streaming: state] ++ get_contexts()
  end

  test "handle_setup should do nothing" do
    mock(:hackney, close: 1)
    assert @module.handle_setup(:stopped, @default_state) == {[], @default_state}
    refute_called(:hackney, :close)
  end

  test "handle_playing/2 should start an async request" do
    ctx = get_contexts()[:ctx_playing]

    mock(:hackney, [request: 5], {:ok, :mock_response})

    state =
      @default_state
      |> Map.merge(%{
        headers: [:hd],
        hackney_opts: [opt: :some],
        body: "body"
      })

    actions = [stream_format: {:output, %RemoteStream{type: :bytestream}}]
    assert {^actions, new_state} = @module.handle_playing(ctx, state)
    assert new_state.async_response == :mock_response
    assert new_state.streaming == true

    assert_called(:hackney, :request, [
      :get,
      "url",
      [:hd],
      "body",
      [opt: :some, stream_to: _, async: :once]
    ])
  end

  describe "handle_demand/5 should" do
    setup :get_contexts

    test "request next chunk if it haven't been already" do
      state = %{@default_state | async_response: :mock_response}
      mock(:hackney, [stream_next: 1], :ok)

      assert {[], new_state} = @module.handle_demand(:output, 42, :bytes, nil, state)
      assert new_state.async_response == :mock_response
      assert new_state.streaming == true

      pin_response = :mock_response

      assert_called(:hackney, :stream_next, [^pin_response])
    end

    test "return error when stream_next fails", %{ctx_demand: ctx} do
      state = %{@default_state | async_response: :mock_response}
      mock(:hackney, [stream_next: 1], {:error, :reason})
      mock(:hackney, close: 1)

      assert_raise RuntimeError,
                   ~r/Max.*retries.*number.*reached.*Retry.*reason.*stream_next.*reason/,
                   fn -> @module.handle_demand(:output, 42, :bytes, ctx, state) end

      pin_response = :mock_response
      assert_called(:hackney, :stream_next, [^pin_response])

      tag = @module.get_resource_tag()
      assert_resource_guard_cleanup(ctx.resource_guard, ^tag)
    end

    test "do nothing when next chunk from :hackney was requested" do
      state = %{@default_state | streaming: true}
      mock(:hackney, [stream_next: 1], {:ok, :mock_response})

      assert @module.handle_demand(:output, 42, :bytes, nil, state) == {[], state}
      refute_called(:hackney, :stream_next)
    end
  end

  defp test_msg_trigger_redemand(msg, ctx, state) do
    assert {actions, new_state} = @module.handle_info(msg, ctx, state)
    assert actions == [redemand: :output]
    assert new_state.streaming == false
  end

  describe "handle_info/3 for message" do
    setup :state_streaming

    test "async status 200 should trigger redemand with streaming false", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, {:status, 200, "OK"}}
      test_msg_trigger_redemand(msg, ctx, state)
    end

    test "async status 206 should trigger redemand with streaming false", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, {:status, 206, "206"}}
      test_msg_trigger_redemand(msg, ctx, state)
    end

    test "async status 301 should return error and close connection", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, {:status, 301, "301"}}
      mock(:hackney, [close: 1], :ok)

      assert_raise RuntimeError,
                   ~r/Max.*retries.*number.*reached.*Retry.*reason.*hackney.*redirect/,
                   fn -> @module.handle_info(msg, ctx, state) end

      tag = @module.get_resource_tag()
      assert_resource_guard_cleanup(ctx.resource_guard, ^tag)
    end

    test "async status 302 should should return error and close connection", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, {:status, 302, "302"}}
      mock(:hackney, [close: 1], :ok)

      assert_raise RuntimeError,
                   ~r/Max.*retries.*number.*reached.*Retry.*reason.*hackney.*redirect/,
                   fn -> @module.handle_info(msg, ctx, state) end

      tag = @module.get_resource_tag()
      assert_resource_guard_cleanup(ctx.resource_guard, ^tag)
    end

    test "async status 416 should should return error and close connection", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, {:status, 416, "416"}}
      mock(:hackney, [close: 1], :ok)

      assert_raise RuntimeError,
                   ~r/Max.*retries.*number.*reached.*Retry.*reason.*hackney.*invalid_range/,
                   fn -> @module.handle_info(msg, ctx, state) end

      tag = @module.get_resource_tag()
      assert_resource_guard_cleanup(ctx.resource_guard, ^tag)
    end

    test "async status with unsupported code should return error and close connection", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      mock(:hackney, [close: 1], :ok)
      codes = [500, 501, 502, 402, 404]

      codes
      |> Enum.each(fn code ->
        msg = {:hackney_response, :mock_response, {:status, code, "#{code}"}}

        assert_raise RuntimeError,
                     ~r/Max.*retries.*number.*reached.*Retry.*reason.*http_code/,
                     fn -> @module.handle_info(msg, ctx, state) end
      end)

      tag = @module.get_resource_tag()
      assert_resource_guard_cleanup(ctx.resource_guard, ^tag)
    end

    test "async headers should trigger redemand with streaming false", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, {:headers, []}}
      test_msg_trigger_redemand(msg, ctx, state)
    end

    test "async chunk when not playing should ignore the data", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, <<>>}
      ctx = Map.put(ctx, :playback, :prepared)
      assert {[], new_state} = @module.handle_info(msg, ctx, state)
      assert new_state.streaming == false
    end

    test "async chunk should produce buffer, update pos_counter and trigger redemand", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, <<1, 2, 3>>}
      assert {actions, new_state} = @module.handle_info(msg, ctx, state)

      assert [buffer: buf_action, redemand: :output] = actions
      assert buf_action == {:output, %Membrane.Buffer{payload: <<1, 2, 3>>}}

      assert new_state.pos_counter == state.pos_counter + 3
      assert new_state.streaming == false
    end

    test "async end should send EOS event and remove asyn_response from state", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      msg = {:hackney_response, :mock_response, :done}
      assert {actions, new_state} = @module.handle_info(msg, ctx, state)
      assert actions == [end_of_stream: :output]
      assert new_state.async_response == nil
      assert new_state.streaming == false
    end

    test ":hackney error should return error and close request", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      mock(:hackney, [close: 1], :ok)
      msg = {:hackney_response, :mock_response, {:error, :reason}}

      assert_raise RuntimeError,
                   ~r/Max.*retries.*number.*reached.*Retry.*reason.*hackney.*reason/,
                   fn -> @module.handle_info(msg, ctx, state) end

      tag = @module.get_resource_tag()
      assert_resource_guard_cleanup(ctx.resource_guard, ^tag)
    end

    test "async redirect should change location and start create new request", %{
      state_streaming: state,
      ctx_info: ctx
    } do
      second_response = :mock_response2
      mock(:hackney, [close: 1], :ok)
      mock(:hackney, [request: 5], {:ok, second_response})

      state =
        state
        |> Map.merge(%{
          headers: [:hd],
          hackney_opts: [opt: :some],
          body: "body"
        })

      msg = {:hackney_response, :mock_response, {:redirect, "url2", []}}
      assert {[], new_state} = @module.handle_info(msg, ctx, state)
      assert new_state.location == "url2"
      assert new_state.async_response == second_response
      assert new_state.streaming == true

      assert_called(:hackney, :request, [
        :get,
        "url2",
        [:hd],
        "body",
        [opt: :some, stream_to: _, async: :once]
      ])

      tag = @module.get_resource_tag()
      assert_resource_guard_register(ctx.resource_guard, cleanup_function, ^tag)

      refute_called(:hackney, :close)

      cleanup_function.()

      assert_called(:hackney, :close, [^second_response])
    end
  end

  defp state_resume_not_live(_params) do
    state =
      @default_state
      |> Map.merge(%{
        max_retries: 1,
        async_response: :mock_response,
        pos_counter: 42
      })

    second_response = :mock_response2
    expected_headers = [{"Range", "bytes=42-"}]

    [
      state: state,
      second_response: second_response,
      expected_headers: expected_headers
    ] ++ get_contexts()
  end

  defp test_reconnect(ctx, resource_guard, tested_call) do
    %{
      second_response: second_response,
      state: state,
      expected_headers: expected_headers
    } = ctx

    mock(:hackney, [close: 1], :ok)
    mock(:hackney, [request: 5], {:ok, ctx.second_response})

    assert {[], new_state} = tested_call.(state)
    assert new_state.async_response == second_response
    assert new_state.streaming == true

    assert_called(:hackney, :request, [
      :get,
      "url",
      ^expected_headers,
      "",
      [stream_to: _, async: :once]
    ])

    tag = @module.get_resource_tag()
    assert_resource_guard_cleanup(resource_guard, ^tag)
  end

  describe "with max_retries = 1 in options" do
    setup :state_resume_not_live

    test "handle_demand should reconnect on error starting from current position",
         %{ctx_demand: ctx_demand} = test_ctx do
      mock(:hackney, [stream_next: 1], {:error, :reason})

      test_reconnect(test_ctx, ctx_demand.resource_guard, fn state ->
        @module.handle_demand(:output, 42, :bytes, ctx_demand, state)
      end)

      assert_called(:hackney, :stream_next, [:mock_response])
    end

    test "handle_info should send :reconnect on error", %{state: state, ctx_info: ctx} do
      msg = {:hackney_response, :mock_response, {:error, :reason}}
      mock(:hackney, [close: 1], :ok)
      assert {[], new_state} = @module.handle_info(msg, ctx, state)
      assert new_state.retries == state.retries + 1
      assert_receive :reconnect
    end
  end

  defp state_resume_live(_params) do
    state =
      @default_state
      |> Map.merge(%{
        max_retries: 1,
        is_live: true,
        async_response: :mock_response,
        pos_counter: 42
      })

    second_response = :mock_response2

    [
      state: state,
      second_response: second_response,
      expected_headers: []
    ] ++ get_contexts()
  end

  describe "with max_retries = 1 and is_live: true in options" do
    setup :state_resume_live

    test "handle_demand should reconnect on error", %{ctx_demand: ctx_demand} = test_ctx do
      mock(:hackney, [stream_next: 1], {:error, :reason})

      test_reconnect(test_ctx, ctx_demand.resource_guard, fn state ->
        @module.handle_demand(:output, 42, :bytes, ctx_demand, state)
      end)

      # trick to overcome Mockery limitations
      pin_response = :mock_response
      assert_called(:hackney, :stream_next, [^pin_response])
    end

    test "handle_info", %{state: state, ctx_info: ctx} do
      msg = {:hackney_response, :mock_response, {:error, :reason}}
      mock(:hackney, [close: 1], :ok)
      assert {[], new_state} = @module.handle_info(msg, ctx, state)
      assert new_state.retries == state.retries + 1
      assert_receive :reconnect
    end
  end
end
