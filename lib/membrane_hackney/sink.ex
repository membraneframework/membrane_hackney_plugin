defmodule Membrane.Hackney.Sink do
  @moduledoc """
  An element uploading data over HTTP(S) based on Hackney
  """
  use Membrane.Sink

  import Mockery.Macro

  alias Membrane.Buffer
  alias Membrane.ResourceGuard

  def_input_pad :input, accepted_format: _any, demand_unit: :bytes

  def_options location: [
                type: :string,
                description: """
                The URL of a request
                """
              ],
              method: [
                type: :atom,
                spec: :post | :put | :patch,
                description: "HTTP method that will be used when making a request",
                default: :post
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
              demand_size: [
                type: :integer,
                description: "The size of the demand made after each write",
                default: 1024
              ]

  defmodule Response do
    @moduledoc """
    Struct containing HTTP response sent to pipeline via notification after the upload is finished.
    """

    @type t :: %__MODULE__{
            status: non_neg_integer(),
            headers: [{String.t(), String.t()}],
            body: String.t()
          }

    @enforce_keys [:status, :headers, :body]
    defstruct @enforce_keys
  end

  @impl true
  def handle_init(_ctx, opts) do
    state = opts |> Map.from_struct() |> Map.merge(%{conn_ref: nil})
    {[], state}
  end

  @impl true
  def handle_playing(ctx, state) do
    {:ok, conn_ref} =
      mockable(:hackney).request(
        state.method,
        state.location,
        state.headers,
        :stream,
        state.hackney_opts
      )

    ResourceGuard.register(
      ctx.resource_guard,
      fn -> mockable(:hackney).close(conn_ref) end,
      tag: {:conn_ref, conn_ref}
    )

    {[demand: {:input, state.demand_size}], %{state | conn_ref: conn_ref}}
  end

  @impl true
  def handle_write(:input, %Buffer{payload: payload}, _ctx, state) do
    mockable(:hackney).send_body(state.conn_ref, payload)
    {[demand: {:input, state.demand_size}], state}
  end

  @impl true
  def handle_end_of_stream(:input, _ctx, %{conn_ref: conn_ref} = state) do
    {:ok, status, headers, conn_ref} = mockable(:hackney).start_response(conn_ref)
    {:ok, body} = mockable(:hackney).body(conn_ref)

    response_notification = %__MODULE__.Response{status: status, headers: headers, body: body}
    {[notify_parent: response_notification, notify_parent: {:end_of_stream, :input}], state}
  end
end
