defmodule SystemMonitor.Events do
  @moduledoc false

  @pubsub SystemMonitor.PubSub

  @system_topic "system:events"
  @worker_topic "worker:commands"

  # ---- generic helpers ----
  def subscribe(topic), do: Phoenix.PubSub.subscribe(@pubsub, topic)
  def unsubscribe(topic), do: Phoenix.PubSub.unsubscribe(@pubsub, topic)

  def broadcast(topic, message),
    do: Phoenix.PubSub.broadcast(@pubsub, topic, message)

  def broadcast_from_self(topic, message),
    do: Phoenix.PubSub.broadcast_from(@pubsub, self(), topic, message)

  # ---- system events ----
  def subscribe_system_events, do: subscribe(@system_topic)

  def reload_configuration(source \\ :unknown) do
    broadcast(@system_topic, {:reload_configuration, %{source: source}})
  end

  # ---- worker commands ----
  # per-host/topic lets only relevant worker receive it
  def worker_topic(host), do: "#{@worker_topic}:#{host}"

  def subscribe_worker_commands(host), do: subscribe(worker_topic(host))

  def send_worker_command(host, command, meta \\ %{}) do
    broadcast(worker_topic(host), {:worker_command, command, meta})
  end
end
