defmodule SystemMonitor.Config.Systems do
  @moduledoc """
  Represents a system configuration with connection credentials. 
  """

  @enforce_keys [:name, :ip, :username]
  defstruct [
    :name,
    :ip,
    :username,
    :password,
    :ssh_key_path,
    :sudo_password,
    port: 22,
    enabled:  true,
    timeout: 30_000
  ]

  @type t :: %__MODULE__{
          name: String.t(),
          ip: String.t(),
          username: String.t(),
          password: String.t() | nil,
          sudo_password: String.t() | nil,
          ssh_key_path: String.t() | nil,
          port: integer(),
          enabled: boolean(),
          timeout: integer()
        }

  def from_map(map) do
    %__MODULE__{
      name: Map.fetch!(map, "name"),
      ip: Map.fetch!(map, "ip"),
      username: Map.fetch!(map, "username"),
      password: Map.get(map, "password"),
      sudo_password: Map.get(map, "sudo_password"),
      ssh_key_path: Map. get(map, "ssh_key_path"),
      port: Map.get(map, "port", 22),
      enabled: Map.get(map, "enabled", true),
      timeout: Map. get(map, "timeout", 30_000)
    }
  end

  def validate(%__MODULE__{} = system) do
    cond do
      is_nil(system.password) and is_nil(system.ssh_key_path) ->
        {:error, "Either password or ssh_key_path must be provided for #{system.name}"}

      system.ssh_key_path && !File.exists?(system.ssh_key_path) ->
        {:error, "SSH key not found:  #{system.ssh_key_path}"}

      true ->
        :ok
    end
  end
end
