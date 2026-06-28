ExUnit.start()

Mox.defmock(SystemMonitor.MockScanner, for: SystemMonitor.ScannerBehaviour)

Application.put_env(:system_monitor, :scanner, SystemMonitor.MockScanner)
