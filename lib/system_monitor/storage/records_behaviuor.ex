defmodule SystemMonitor.Storage.RecordsBehaviour do
  @moduledoc """
  Define records storage behavoiur
  """
  @callback store(map()) :: :ok | {:error, term()}
  @callback get_latest_for_all_systems() :: list()
end
