defmodule SystemMonitor.Storage.RecordsBehaviour do
  @callback store(map()) :: any()
end
