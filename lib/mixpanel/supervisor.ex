defmodule Mixpanel.Supervisor do
  use Supervisor

  @moduledoc """


  """

  def start_link(app) do
    config = Application.get_env(app, :mixpanel)

    Supervisor.start_link(__MODULE__, config)
  end

  def init(config) do
    if !config[:token] do
      raise "Please set :mixpanel, :token in your app environment's config"
    end

    children = [
      worker(Mixpanel.Client, [config, [name: Mixpanel.Client]])
    ]

    supervise(children, strategy: :one_for_one, name: Mixpanel.Supervisor)
  end
end
