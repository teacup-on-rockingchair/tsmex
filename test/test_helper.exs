ExUnit.start()

Mox.defmock(SystemMonitor.MockScanner, for: SystemMonitor.ScannerBehaviour)

Application.put_env(:system_monitor, :scanner, SystemMonitor.MockScanner)

Mox.defmock(SystemMonitor.SSH.CommandRunnerMock, for: SystemMonitor.SSH.CommandRunnerBehaviour)

Mox.defmock(SystemMonitor.SSH.ClientMock, for: SystemMonitor.SSH.ClientBehaviour)

Mox.defmock(SystemMonitor.Storage.RecordsMock, for: SystemMonitor.Storage.RecordsBehaviour)

Mox.defmock(SystemMonitor.Config.LoaderMock, for: SystemMonitor.Config.LoaderBehaviour)
