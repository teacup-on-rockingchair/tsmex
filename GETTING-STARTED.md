
## TSMEX Getting Started 

### 1) What TSMEX expects at runtime

TSMEX loads **external JSON config files** (not hardcoded DB setup):

- `SYSTEMS_CONFIG_PATH` → systems and IP range
- `COMMANDS_CONFIG_PATH` → commands to run over SSH
- `SERVICES_CONFIG_PATH` → required/optional services (if used by your checks)

If not set, defaults are:

- `~/.system_monitor/systems.json`
- `~/.system_monitor/commands.json`
- `~/.system_monitor/services.json`

So the core setup is: **prepare these files first**.

---

### 2) Create local config directory and files

```bash
mkdir -p ~/.system_monitor
```

#### `~/.system_monitor/systems.json`
Use your proven test shape:

```json
{
  "ip_range": ["192.168.1.100", "192.168.1.110"],
  "systems": [
    {
      "enabled": true,
      "ip": "192.168.1.100",
      "name": "analyzer-01",
      "username": "admin",
      "password": "password1",
      "port": 22
    }
  ]
}
```

Rules from implementation/tests:
- `ip_range` must exist and contain **exactly 2 valid IPs**
- start IP must be `<=` end IP
- systems with `"enabled": false` are ignored
- auth supports password and/or `ssh_key_path` fields (your test data includes both in some entries)

---

### 3) Create commands config (required for monitor worker)

TSMEX parses `commands` with strict fields (`id`, `description`, `command`, `format`), where format must be one of:
- `raw`
- `icon`
- `extract`

Also supports output sanitization noise patterns.

Example `~/.system_monitor/commands.json`:

```json
{
  "commands": [
    {
      "id": "uptime",
      "description": "System uptime",
      "command": "uptime",
      "format": "raw",
      "order": 1,
      "enabled": true,
      "timeout": 1000
    },
    {
      "id": "ver",
      "description": "Version",
      "command": "cat /etc/os-release",
      "format": "raw",
      "order": 2,
      "enabled": true,
      "timeout": 1000
    }
  ],
  "output_sanitization": {
    "noise_patterns": ["We trust you have received the usual lecture"]
  }
}
```

---

### 6) Define services configuration
`services.json` in this app is a **health classification policy file**, not connection config, with the format of comma separated service names grouped in two lists:

```json
{
  "required_services": [...],
  "optional_services": [...]
}
```
So practically:

- **required services** likely drive “critical” health (missing required -> red)
- **optional services** likely influence warning state (missing optional -> yellow)

That mapping is inferred from the status model (`:green/:yellow/:red`) and naming; exact rules live in `SystemMonitorWeb.DashboardLive.SystemHealth`.


---

### 5) Export config paths (recommended explicitly)

```bash
export SYSTEMS_CONFIG_PATH="$HOME/.system_monitor/systems.json"
export COMMANDS_CONFIG_PATH="$HOME/.system_monitor/commands.json"
export SERVICES_CONFIG_PATH="$HOME/.system_monitor/services.json"
```

(You can skip if using default paths above.)

---

### 6) Install deps and start app

```bash
mix deps.get
mix phx.server
```

Open `http://localhost:4000`.

---

### 7) Run tests as setup validation

```bash
mix test
```

Key suites to trust for bootstrapping correctness:
- `SystemMonitor.ConfigLoaderTest` (config file parsing/validation)
- `SystemMonitor.SSH.CommandRunnerTest` (batch SSH execution semantics)
- `SystemMonitor.Scheduler.MonitorWorkerBatchTest` (worker + store + PubSub behavior)
- `SystemMonitor.BodyCountTest` (failure tracking/rescan threshold logic)

---

## First-Time Operator Checklist (TSMEX-specific)

- [ ] `systems.json` has valid `ip_range` of 2 valid addresses  
- [ ] each system has reachable SSH endpoint (`ip`, `port`, `username`, auth)  
- [ ] `commands.json` command `format` only in `raw|icon|extract`  
- [ ] app starts and can run at least one command batch  

---
