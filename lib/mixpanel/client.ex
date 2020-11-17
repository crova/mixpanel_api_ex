defmodule Mixpanel.Client do
  use GenServer

  @moduledoc """
  Mixpanel batch API client
  """

  require Logger

  alias Mixpanel.Queue

  @track_endpoint "https://api.mixpanel.com/track"
  @engage_endpoint "https://api.mixpanel.com/engage"

  @headers [{"Content-Type", "application/x-www-form-urlencoded"}]

  @defaults %{
    max_queue_track: 200,
    max_queue_engage: 500,
    batch_size: 50,
    max_idle: 500
  }

  def start_link(config, opts \\ []) do
    GenServer.start_link(__MODULE__, {:ok, config}, opts)
  end

  @doc """
  Tracks a event

  See `Mixpanel.track/3`
  """
  @spec track(String.t(), Map.t(), Atom.t()) :: :ok
  def track(event, properties \\ %{}, process \\ nil) do
    GenServer.cast(process || __MODULE__, {:track, event, properties})
  end

  @doc """
  Updates a user profile.

  See `Mixpanel.engage/4`.
  """
  @spec engage(Map.t()) :: :ok
  def engage(event, process \\ nil) do
    GenServer.cast(process || __MODULE__, {:engage, event})
  end

  def init({:ok, opts}) do
    config = Enum.into(opts, @defaults)

    state = %{
      track: Queue.new(config.max_queue_track),
      engage: Queue.new(config.max_queue_engage),
      track_dropped: 0,
      engage_dropped: 0
    }

    {:ok, {config, state}}
  end

  # No events submitted when env configuration is set to false or no token is
  # configured.
  def handle_cast(_request, {%{active: false}, _} = state) do
    {:noreply, state}
  end

  def handle_cast(_request, {%{token: nil}, _} = state) do
    {:noreply, state}
  end

  def handle_cast({:track, _event, _properties} = event, {config, state}) do
    case Queue.push(state.track, event) do
      :dropped ->
        new_state = Map.update!(state, :track_dropped, &(&1 + 1))
        {:noreply, {config, new_state}, 0}

      {:ok, queue} ->
        timeout = receive_timeout(queue, config)
        {:noreply, {config, %{state | track: queue}}, timeout}
    end
  end

  def handle_cast({:engage, _event} = event, {config, state}) do
    case Queue.push(state.engage, event) do
      :dropped ->
        new_state = Map.update!(state, :engage_dropped, &(&1 + 1))
        {:noreply, {config, new_state}, 0}

      {:ok, queue} ->
        timeout = receive_timeout(queue, config)
        {:noreply, {config, %{state | engage: queue}}, timeout}
    end
  end

  def handle_info(:timeout, {%{batch_size: batch_size} = config, state}) do
    new_state =
      state
      |> report_dropped(config.app)
      |> engage_batch(batch_size, config)
      |> track_batch(batch_size, config)

    case {Queue.length(new_state.track), Queue.length(new_state.engage)} do
      {0, 0} ->
        {:noreply, {config, new_state}}

      {len1, len2} when len1 >= batch_size or len2 >= batch_size ->
        {:noreply, {config, new_state}, 0}

      _ ->
        {:noreply, {config, new_state}, config.max_idle}
    end
  end

  # Workaround for Hackney bug; unfortunately this interferes with the idle
  # timeout handling, but since it is relatively rare it will have to do for
  # now
  def handle_info({:ssl_closed, _sock}, {config, state}) do
    {:noreply, {config, state}, config.max_idle}
  end

  defp receive_timeout(queue, config) do
    if Queue.length(queue) >= config.batch_size do
      0
    else
      config.max_idle
    end
  end

  defp report_dropped(%{track_dropped: 0, engage_dropped: 0} = state, _otp_app) do
    state
  end

  defp report_dropped(%{track_dropped: count} = state, otp_app) when count > 0 do
    :telemetry.execute([otp_app, :mixpanel, :dropped], %{count: count}, %{type: :track})
    report_dropped(%{state | track_dropped: 0}, otp_app)
  end

  defp report_dropped(%{engage_dropped: count} = state, otp_app) when count > 0 do
    :telemetry.execute([otp_app, :mixpanel, :dropped], %{count: count}, %{type: :engage})
    report_dropped(%{state | engage_dropped: 0}, otp_app)
  end

  defp track_batch(state, batch_size, config) do
    case Queue.take(state.track, batch_size) do
      {[], _queue} ->
        state

      {batch, queue} ->
        encoded = Enum.map(batch, &encode_track(&1, config.token))
        send_batch(@track_endpoint, encoded, :track, config.app)

        %{state | track: queue}
    end
  end

  defp engage_batch(state, batch_size, config) do
    case Queue.take(state.engage, batch_size) do
      {[], _queue} ->
        state

      {batch, queue} ->
        encoded = Enum.map(batch, &encode_engage(&1, config.token))
        send_batch(@engage_endpoint, encoded, :engage, config.app)

        %{state | engage: queue}
    end
  end

  defp encode_track({:track, event, properties}, token) do
    %{
      event: event,
      properties: Map.put(properties, :token, token)
    }
  end

  defp encode_engage({:engage, event}, token) do
    Map.put(event, "$token", token)
  end

  defp send_batch(endpoint, batch, type, app) do
    telemetry_metadata = %{type: type, count: length(batch)}

    data =
      batch
      |> Jason.encode!()
      |> URI.encode_www_form()

    :telemetry.span([app, :mixpanel, :batch], telemetry_metadata, fn ->
      success? = http_post(endpoint, @headers, "data=" <> data)
      {success?, Map.put(telemetry_metadata, :success, success?)}
    end)
  end

  defp http_post(url, headers, body) do
    case HTTPoison.post(url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: "1"}} ->
        true

      other ->
        Logger.warn("Problem tracking Mixpanel engagements: #{inspect(other)}")
        false
    end
  end
end
