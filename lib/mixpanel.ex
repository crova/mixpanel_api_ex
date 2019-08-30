defmodule Mixpanel do
  @moduledoc """
  Elixir client for the Mixpanel API.
  """

  defmacro __using__(opts) do
    quote do
      require Logger
      use Supervisor

      @otp_app unquote(opts)[:otp_app]

      def child_spec(opts) do
        %{
          id: __MODULE__,
          start: {__MODULE__, :start_link, [opts]},
          type: :supervisor
        }
      end

      def start_link(opts) do
        config = Application.get_env(@otp_app, :mixpanel)

        if config do
          Supervisor.start_link(__MODULE__, Enum.into(config, %{app: @otp_app}))
        else
          Logger.warn("Mixpanel not configured for application #{@otp_app}")
          :ignore
        end
      end

      def init(config) do
        children = [
          worker(Mixpanel.Client, [config, [name: get_process_name()]])
        ]

        supervise(children, strategy: :one_for_one)
      end

      def track(event, properties \\ %{}, opts \\ []) do
        opts = Keyword.merge(opts, process: get_process_name())
        Mixpanel.Dispatcher.track(event, properties, opts)
      end

      def engage(distinct_id, operation, value \\ %{}, opts \\ []) do
        opts = Keyword.merge(opts, process: get_process_name())
        Mixpanel.Dispatcher.engage(distinct_id, operation, value, opts)
      end

      defp get_process_name() do
        :"mixpanel_#{@otp_app}"
      end
    end
  end
end
