defmodule SystemMonitor.SSH.ClientBehaviour do
  @callback connect(map()) :: {:ok, term()} | {:error, term()}
  @callback execute(term(), String.t(), non_neg_integer(), String.t() | nil) ::
              {:ok, String.t()} | {:error, term()}
  @callback disconnect(term()) :: any()
end
