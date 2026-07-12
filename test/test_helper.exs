ExUnit.start()

Mox.defmock(SystemMonitor.MockScanner, for: SystemMonitor.ScannerBehaviour)

Application.put_env(:system_monitor, :scanner, SystemMonitor.MockScanner)

Mox.defmock(SystemMonitor.SSH.CommandRunnerMock, for: SystemMonitor.SSH.CommandRunnerBehaviour)

Mox.defmock(SystemMonitor.SSH.ClientMock, for: SystemMonitor.SSH.ClientBehaviour)
