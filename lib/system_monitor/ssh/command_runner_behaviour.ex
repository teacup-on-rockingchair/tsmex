defmodule SystemMonitor.SSH.CommandRunnerBehaviour do
  @moduledoc false

  @callback execute(map(), String.t(), non_neg_integer(), String.t() | nil) ::
              String.t() | {:error, term()}

  @callback execute_batch(map(), list(), keyword()) ::
              {:ok, list()} | {:error, term()}
end
