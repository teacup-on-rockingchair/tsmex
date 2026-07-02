defmodule SystemMonitor.Scanner do
  @moduledoc """
  Perform search for a system in the network, based on attempt to login via ssh with given credentials
  """

  require Logger

  def scan(ip_address_range, username, password) do
    # Placeholder implementation for the scanner.
    # In a real-world scenario, this function would contain logic to scan the network.
    # For now, it simply returns an empty list to simulate no system found.
    result = scan_with_passwords(ip_address_range, username, [password])[0]
    Logger.info("Scan completed for range #{ip_address_range} with username #{username} and password #{password} with result: #{inspect(result)}")
  end

  defp scan_with_passwords(ip_range, username, passwords) do
    Enum.reduce_while(passwords, ip_range, fn password, remaining_ips ->
      Logger.info("Trying password: #{password} #{username} and #{length(remaining_ips)} IPs remaining")
      
      new_remaining = scan_ips_with_password(remaining_ips, username, password)
      
      if Enum.empty?(new_remaining) do
        {:halt, []}
      else
        {:cont, new_remaining}
      end
    end)
  end

  
  defp scan_ips_with_password(ip_ints, username, password) do
    # Use Task.async_stream for concurrent processing
    atomics = :atomics.new(1, [])
    ip_ints
    |> Task.async_stream(
    fn ip_int ->
      ip = int_to_ip(ip_int)
      #IO.puts("Trying #{ip}")
      case :atomics.get(atomics, 1) do
        1 ->
          {:skipped, ip_int}
        _ ->
          :ok   
          case try_ssh_connection(ip, username, password) do
            :success ->
              IO.puts("Successfully connected to #{ip} with [#{password}]")
              :atomics.put(atomics, 1, 1) # Mark this IP as successful
              {:success, ip_int}
              
              :failure ->
              #         IO.puts("Failed to connect to #{ip}")
              {:failure, ip_int}
          end
      end
    end,
    max_concurrency: 20,  # Adjust based on your needs
    timeout: 10_000,      # 10 second timeout per connection
    on_timeout: :kill_task
    )
    |> Enum.reduce([], fn 
    {:ok, {:success, _ip_int}}, remaining ->
        remaining  # Remove successful IPs from remaining list
      
      {:ok, {:failure, ip_int}}, remaining ->
        [ip_int | remaining]  # Keep failed IPs in remaining list
      
      {:exit, _reason}, remaining ->
        remaining  # Handle timeouts/crashes
      {:ok, {:skipped, _reason}}, _remaining ->
        []  # Handle timeouts/crashes

    end)
    |> Enum.reverse()
  end
  
  defp try_ssh_connection(ip, username, password) do
    ssh_args = [
      "-p", password,
      "ssh", 
      "-o", "StrictHostKeyChecking=no",
      "-o", "UserKnownHostsFile=/dev/null", 
      "-o", "LogLevel=ERROR",
      "-o", "ConnectTimeout=5",
      "-o", "PreferredAuthentications=password",
      "-o", "PubkeyAuthentication=no",
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

  # Convert integer to IP address
  defp int_to_ip(num) do
    a = div(num, 256 * 256 * 256) |> rem(256)
    b = div(num, 256 * 256) |> rem(256) 
    c = div(num, 256) |> rem(256)
    d = rem(num, 256)
    
    "#{a}.#{b}.#{c}.#{d}"
  end
  
  

end
