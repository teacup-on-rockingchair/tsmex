defmodule SystemMonitor.Storage.RecordsBehaviour do
  @callback store(map()) :: :ok | {:error, term()}
  @callback get_latest_for_all_systems() :: list()
end
