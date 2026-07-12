defmodule SystemMonitor.Config.Commands do
  @moduledoc """
  Represents a command configuration for system monitoring.
  """

  @enforce_keys [:id, :description, :command, :format]
  defstruct [
    :id,
    :description,
    :command,
    :format,
    order: 999,
    enabled: true,
    timeout: 10_000
  ]

  @type format :: :raw | :icon | :extract

  @type t :: %__MODULE__{
          id: String.t(),
          description: String.t(),
          command: String.t(),
          format: format(),
          order: integer(),
          enabled: boolean(),
          timeout: integer()
        }

  @valid_formats ~w(raw icon extract)

  def from_map(map) do
    format_str = Map.fetch!(map, "format")

    unless format_str in @valid_formats do
      raise "Invalid format '#{format_str}' for command #{map["id"]}. " <>
              "Must be one of: #{Enum.join(@valid_formats, ", ")}"
    end

    %__MODULE__{
      id: Map.fetch!(map, "id"),
      description: Map.fetch!(map, "description"),
      command: Map.fetch!(map, "command"),
      format: String.to_atom(format_str),
      order: Map.get(map, "order", 999),
      enabled: Map.get(map, "enabled", true),
      timeout: Map.get(map, "timeout", 10_000)
    }
  end
end
