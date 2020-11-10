defmodule MixpanelTest do
  use ExUnit.Case

  import Mock

  @events [[:mixpanel, :batch, :start], [:mixpanel, :batch, :stop], [:mixpanel, :dropped]]

  setup do
    config = [
      active: true,
      token: "",
      max_idle: 75,
      batch_size: 3,
      max_queue_track: 5,
      max_queue_engage: 5
    ]
    pid = start_supervised!({Mixpanel.Client, config})

    {:ok, pid: pid}
  end

  describe "track" do
    test "track an event", %{pid: pid} do
      with_mock HTTPoison, post: &mock_post/3 do
        track(pid)

        :timer.sleep(100)

        assert %{requests: 1, items: 1} = collect_requests()
      end
    end

    test "track multiple events", %{pid: pid} do
      with_mock HTTPoison, post: &mock_post/3 do
        for _ <- 1..3, do: track(pid)

        :timer.sleep(100)

        assert %{requests: 1, items: 3} = collect_requests()
      end
    end

    test "max queue size", %{pid: pid} do
      with_mock HTTPoison, post: &mock_post/3 do
        for _ <- 1..10, do: track(pid)

        :timer.sleep(100)

        assert %{requests: 2, items: 5} = collect_requests()
      end
    end

    test "telemetry", %{pid: pid} do
      :telemetry.attach_many(make_ref(), @events, &forward_telemetry/4, self())

      with_mock HTTPoison, post: &mock_post/3 do
        for _ <- 1..10, do: track(pid)

        assert_receive {[:mixpanel, :batch, :start], _, _}
        assert_receive {[:mixpanel, :batch, :stop], _, _}
        assert_receive {[:mixpanel, :dropped], %{count: 5}, _}
      end
    end
  end

  describe "engage" do
    test "track an engagement", %{pid: pid} do
      with_mock HTTPoison, post: &mock_post/3 do
        engage(pid)

        :timer.sleep(100)

        assert %{requests: 1, items: 1} = collect_requests()
      end
    end

    test "track multiple engagements", %{pid: pid} do
      with_mock HTTPoison, post: &mock_post/3 do
        for _ <- 1..3, do: engage(pid)

        :timer.sleep(100)

        assert %{requests: 1, items: 3} = collect_requests()
      end
    end

    test "max engagement queue size", %{pid: pid} do
      with_mock HTTPoison, post: &mock_post/3 do
        for _ <- 1..10, do: engage(pid)

        :timer.sleep(100)

        assert %{requests: 2, items: 5} = collect_requests()
      end
    end

    test "engagement telemetry", %{pid: pid} do
      :telemetry.attach_many(make_ref(), @events, &forward_telemetry/4, self())

      with_mock HTTPoison, post: &mock_post/3 do
        for _ <- 1..10, do: engage(pid)

        assert_receive {[:mixpanel, :batch, :start], _, _}
        assert_receive {[:mixpanel, :batch, :stop], _, _}
        assert_receive {[:mixpanel, :dropped], %{count: 5}, _}
      end
    end
  end

  defp mock_post(_, _, _) do
    {:ok, %HTTPoison.Response{status_code: 200, body: "1"}}
  end

  defp track(pid) do
    Mixpanel.Dispatcher.track("Signed up", %{"Referred By" => "friend"},
      distinct_id: "13793",
      process: pid
    )
  end

  defp engage(pid) do
    Mixpanel.Dispatcher.engage("13793", "$set", %{"Address" => "1313 Mockingbird Lane"},
      ip: "123.123.123.123",
      process: pid
    )
  end

  defp collect_requests do
    requests =
      call_history(HTTPoison)
      |> Enum.map(&count_items/1)

    %{requests: length(requests), items: Enum.sum(requests)}
  end

  defp count_items(
         {_, {HTTPoison, :post, ["https://api.mixpanel.com/" <> _, "data=" <> data, _]}, _}
       ) do
    data
    |> URI.decode_www_form()
    |> Jason.decode!()
    |> length()
  end

  defp forward_telemetry(event, measurements, metadata, pid) do
    send(pid, {event, measurements, metadata})
  end
end
