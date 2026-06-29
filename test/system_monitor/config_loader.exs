defmodule SystemMonitor.ConfigLoaderTest do
  use ExUnit.Case, async: true

  alias SystemMonitor.Config.Loader

  setup do
    IO.puts("Setting up BodyCount GenServer for tests...")
  end

  test "loads systems config successfully" do
    System.put_env("SYSTEMS_CONFIG_PATH", "test/support/test_systems.json")
    {:ok, config} = Loader.load_systems_config()
    assert length(config.systems) == 4
    assert length(config.ip_range) == 2
  end

  test "loads system config only in case of correct ip range is configured" do
        System.put_env("SYSTEMS_CONFIG_PATH", "test/support/test_systems_invalid_ip_range.json")
        {:error, :invalid_ip_range} = Loader.load_systems_config()
  end
  

end
