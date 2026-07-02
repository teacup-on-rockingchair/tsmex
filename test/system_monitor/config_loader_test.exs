defmodule SystemMonitor.ConfigLoaderTest do
  use ExUnit.Case, async: true

  alias SystemMonitor.Config.Loader

  setup context do
    IO.puts("Setting up BodyCount GenServer for tests...")
    if context[:modify_test_systems] do
      File.cp("test/support/test_systems.json", "test/support/test_systems_backup.json")

      on_exit(fn ->
        File.cp("test/support/test_systems_backup.json", "test/support/test_systems.json")
        File.rm("test/support/test_systems_backup.json")
      end)
    end
    :ok
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

  @tag :modify_test_systems
  test "Replace IP address of a system successfully" do
    System.put_env("SYSTEMS_CONFIG_PATH", "test/support/test_systems.json")
    {:ok, config} = Loader.load_systems_config()
    IO.puts("Loaded config: #{inspect(config.systems)}")
    lost_system = Enum.find(config.systems, fn system -> Map.get(system,:name) == "analyzer-04" end)
    
    assert Map.get(lost_system, :ip) == "192.168.1.104"
    Loader.set_new_ip(lost_system.username, lost_system.password, "192.168.1.144")
    found_system = Enum.find(config.systems, fn system -> Map.get(system,:name) == "analyzer-04" end)
    assert  Map.get(found_system, :ip) == "192.168.1.104"
    # reload
    {:ok, config} = Loader.load_systems_config()
    loaded_system = Enum.find(config.systems, fn system -> Map.get(system,:name) == "analyzer-04" end)
    assert  Map.get(loaded_system, :ip) == "192.168.1.144"

    # restore the ip to original
    Loader.set_new_ip(lost_system.username, lost_system.password, "192.168.1.144")
    
  end


end
