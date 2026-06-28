defmodule SystemMonitor do
  @moduledoc """
  SystemMonitor keeps the contexts that define your domain
  and business logic.

  Contexts are also responsible for managing your data, regardless
  if it comes from the database, an external API or others.
  """
  def scan(ip_address_range, password) do
    scanner = Application.fetch_env!(:system_monitor, :scanner)
    scanner.scan(ip_address_range, password)
  end
end
