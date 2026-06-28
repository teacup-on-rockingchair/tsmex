defmodule SystemMonitor.ScannerBehaviour do
  @moduledoc """
  Behaviour to scan for systems in the network.
  """

  @callback scan(ip_address_range :: String.t(), password :: String.t()) :: String.t()
end

