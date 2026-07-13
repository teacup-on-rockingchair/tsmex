defmodule SystemMonitor.Scanner do
  @moduledoc """
  Perform search for a system in the network, based on attempt to login via ssh with given credentials
  """

  require Logger
  alias SystemMonitor.Config.Loader
  alias SystemMonitor.Events

  def scan(ip_address_range, username, password) do
    # Placeholder implementation for the scanner.
    # In a real-world scenario, this function would contain logic to scan the network.
    # For now, it simply returns an empty list to simulate no system found.
    start_int = ip_to_int(List.first(ip_address_range))
    end_int = ip_to_int(List.last(ip_address_range))

    ip_range = Enum.to_list(start_int..end_int)

    result_int = List.first(scan_with_passwords(ip_range, username, [password]))
    result = if result_int, do: int_to_ip(result_int), else: nil

    Logger.info(
      "Scan completed for range #{ip_address_range} with username #{username} and password #{password} with result: #{inspect(result)}"
    )

    if result do
      Logger.info("System found at IP: #{result}")
      Loader.set_new_ip(username, password, result)
      Events.reload_configuration(__MODULE__)
    else
      Logger.info("No system found in the given range.")
    end

    result
  end

  defp scan_with_passwords(ip_range, username, passwords) do
    Enum.reduce_while(passwords, ip_range, fn password, remaining_ips ->
      Logger.info(
        "Trying password: #{password} #{username} and #{length(remaining_ips)} IPs remaining"
      )

      new_remaining = scan_ips_with_password(remaining_ips, username, password)

      if Enum.empty?(new_remaining) do
        {:halt, []}
      else
        {:cont, new_remaining}
      end
    end)
  end

  defp schedule_ssh_connection(atomics, ip_int, username, password) do
    ip = int_to_ip(ip_int)

    case try_ssh_connection(ip, username, password) do
      :success ->
        Logger.info("Successfully connected to #{ip} with [#{password}]")
        # Mark this IP as successful
        :atomics.put(atomics, 1, 1)
        {:success, ip_int}

      :failure ->
        {:failure, ip_int}
    end
  end

  defp scan_ips_with_password(ip_ints, username, password) do
    # Use Task.async_stream for concurrent processing
    atomics = :atomics.new(1, [])

    ip_ints
    |> Task.async_stream(
      fn ip_int ->
        case :atomics.get(atomics, 1) do
          1 ->
            {:skipped, ip_int}

          _ ->
            schedule_ssh_connection(atomics, ip_int, username, password)
        end
      end,
      # Adjust based on your needs
      max_concurrency: 20,
      # 10 second timeout per connection
      timeout: 10_000,
      on_timeout: :kill_task
    )
    |> Enum.reduce([], fn
      {:ok, {:success, ip_int}}, successful ->
        # Remove successful IPs from remaining list
        [ip_int | successful]

      {:ok, {:failure, ip_int}}, successful ->
        Logger.info("Failed to connect to #{int_to_ip(ip_int)}")
        # Keep failed IPs in remaining list
        successful

      {:exit, reason}, successful ->
        Logger.info("Task exited with reason: #{inspect(reason)}")
        # Handle timeouts/crashes
        successful

      {:ok, {:skipped, reason}}, successful ->
        Logger.info("Task skipped for reason: #{inspect(reason)}")
        # Handle skipped tasks
        successful
    end)
    |> Enum.reverse()
  end

  defp try_ssh_connection(ip, username, password) do
    ssh_args = [
      "-p",
      password,
      "ssh",
      "-o",
      "StrictHostKeyChecking=no",
      "-o",
      "UserKnownHostsFile=/dev/null",
      "-o",
      "LogLevel=ERROR",
      "-o",
      "ConnectTimeout=5",
      "-o",
      "PreferredAuthentications=password",
      "-o",
      "PubkeyAuthentication=no",
      "#{username}@#{ip}",
      "echo 'Login successful on #{ip}'"
    ]

    case System.cmd("sshpass", ssh_args, stderr_to_stdout: true) do
      {_output, 0} -> :success
      {_output, _exit_code} -> :failure
    end
  rescue
    _ -> :failure
  end

  # Convert IP address to integer
  defp ip_to_int(ip_string) do
    ip_string
    |> String.split(".")
    |> Enum.map(&String.to_integer/1)
    |> case do
      [a, b, c, d] -> a * 256 * 256 * 256 + b * 256 * 256 + c * 256 + d
    end
  end

  # Convert integer to IP address
  defp int_to_ip(num) do
    a = div(num, 256 * 256 * 256) |> rem(256)
    b = div(num, 256 * 256) |> rem(256)
    c = div(num, 256) |> rem(256)
    d = rem(num, 256)

    "#{a}.#{b}.#{c}.#{d}"
  end
end
