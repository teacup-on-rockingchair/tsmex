# System Monitor Configuration

This application requires two external configuration files that should **NOT** be committed to the repository. 

## Setup Instructions

### Quick Setup

```bash
# Create configuration directory
mkdir -p ~/. system_monitor
chmod 700 ~/.system_monitor

# Copy example files
cp config/examples/systems.json.example ~/.system_monitor/systems.json
cp config/examples/commands.json.example ~/.system_monitor/commands.json

# Set permissions
chmod 600 ~/.system_monitor/*. json

# Edit with your actual systems
nano ~/.system_monitor/systems. json
nano ~/.system_monitor/commands.json

# Set environment variables
export SYSTEMS_CONFIG_PATH=~/.system_monitor/systems.json
export COMMANDS_CONFIG_PATH=~/.system_monitor/commands.json
