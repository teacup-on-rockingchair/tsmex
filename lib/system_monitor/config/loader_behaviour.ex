defmodule SystemMonitor.Config.LoaderBehaviour do
  @moduledoc """
  Define Configuration loader behaviour
  """
  @callback load_commands_config() ::
              {:ok, %{commands: list(), noise_patterns: list(String.t())}} | {:error, term()}

  @callback load_services_config() ::
              {:ok, list()} | {:error, term()}
end
