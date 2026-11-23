# UniFi Intelligent Fan Control

This is a fork of [the original by iceteaSA](https://github.com/iceteaSA/unifi-fan-control) to fit my own preferences.

Advanced temperature management for Ubiquiti UniFi OS devices with fan control. And reporting to an optional [SME](https://github.com/diminDDL/simple-message-exchange) server.

Confirmed working on: UCG-Max, UCG-Fibre, UXG-Fibre, UDM-SE, UDM-Pro-Max, UDR7, UNVR

**Not supported: UniFi switches (USW line).** They run BusyBox `sh` with no bash, no
`ubnt-systool` for temperature, and no systemd — and their fans are firmware controlled
rather than exposed as writable `/sys/class/hwmon/*/pwm*`. Confirmed on a USW Enterprise
48 PoE running 7.5.9: no `/sys/class/hwmon/*/pwm*` entries exist at all. This needs
consoles and gateways running full UniFi OS.

## Features
- 🎛️ **Four Operational States**: 
  - **OFF**: Fan disabled (temp < activation threshold)
  - **TAPER**: Post-cooling minimum speed period
  - **ACTIVE**: Quadratic response curve (temp ≥ activation threshold)
  - **EMERGENCY**: Immediate full speed (255 PWM) (critical temps)
- 🚨 **Emergency Override**: Instant full speed at critical temps with hysteresis for stable transitions
- 📈 **Quadratic Response**: Progressive cooling curve for optimal noise/performance
- 🧠 **Enhanced Adaptive Learning**: Intelligent PWM optimization with temperature trend analysis
- 📉 **Exponential Smoothing**: Noise-resistant temperature tracking
- 🛡️ **Robust Safety Systems**: 
  - Speed limits and thermal protection
  - Hardware validation
  - Sensor failure detection and recovery
  - Configuration validation
- 🔄 **State Transition Hysteresis**: Prevents rapid state oscillation
- 🔍 **Multi-Fan Auto-Detection**: Automatically discovers and controls all active fan channels
  - Searches hwmon class directories first (UCG-Max, UNVR)
  - Falls back to raw sysfs device paths when needed (UDM-SE)
  - Identifies active fans by RPM reading and write-tests each channel
  - All detected fans receive the same PWM value
- 📋 **Remote Logging**: Integrated logging into an [SME](https://github.com/diminDDL/simple-message-exchange) server (optional).
- **Drive Temperature Floor**: Raises PWM for a hot NVMe or SATA drive without changing the CPU curve

## Installation
```bash
curl -fsSL https://raw.githubusercontent.com/diminDDL/unifi-fan-control/main/install.sh | sudo bash
```

This fork does not publish signed releases, so by default the installer downloads
the runtime files from the `main` branch (unverified). The files are still
size- and syntax-checked before anything under `/data` is replaced.

### Using a Different Branch
```bash
curl -fsSL https://raw.githubusercontent.com/diminDDL/unifi-fan-control/main/install.sh | sudo FAN_CONTROL_BRANCH=feature/example bash
```

### Manual Installation
If you prefer to inspect the code before installation:
```bash
# Clone the repository
git clone https://github.com/diminDDL/unifi-fan-control.git
cd unifi-fan-control

# Run the installer from a checkout or extracted release tarball
sudo ./install.sh
```

When all four runtime files are beside `install.sh`, the installer uses those
local files without a network request.

## Configuration
Edit `/data/fan-control/config`:
```bash
# Core Thresholds
MIN_TEMP=60            # Base threshold (°C)
MAX_TEMP=85            # Critical temperature (°C)
HYSTERESIS=5           # Temperature buffer (°C)

# Fan Behavior
MIN_PWM=91        # Minimum active speed (0-255)
MAX_PWM=255       # Maximum speed (0-255)
MAX_PWM_STEP=25   # Maximum speed change per adjustment
                  # Note: Due to hardware limitations, actual PWM values may vary slightly from requested values

# Drive Temperature Floor
# auto detects a readable NVMe or SATA drive; false skips detection entirely
DRIVE_TEMP_ENABLED=auto
DRIVE_MIN_TEMP=50        # Start raising the PWM floor (°C)
DRIVE_MAX_TEMP=70        # Reach maximum PWM (°C)
DRIVE_CHECK_INTERVAL=60  # Drive temperature polling interval (seconds)

# Advanced Tuning
ALPHA=20          # Smoothing factor, lower values make the smoothed temp follow raw temp more closely (0-100 raw→smooth)
DEADBAND=1        # Temperature stability threshold (°C)
LEARNING_RATE=5   # Hourly PWM optimization step size
TAPER_MINS=90     # Cool-down duration (minutes)
CHECK_INTERVAL=15 # Temperature check frequency (seconds)

# Auto-detects all active fan channels by default (recommended)
# Set to false to use FAN_PWM_DEVICE as a single manual override instead
FAN_PWM_AUTODETECT=true
# Only used when FAN_PWM_AUTODETECT=false
FAN_PWM_DEVICE="/sys/class/hwmon/hwmon0/pwm1"
OPTIMAL_PWM_FILE="/run/fan-control/optimal_pwm"
```

Runtime state files are intentionally volatile and stored in `/run/fan-control`:
- Smoothed temperature cache: `/run/fan-control/temp_state`
- Learned PWM profile: `/run/fan-control/optimal_pwm`
These are recreated automatically and relearned after reboot.

To put them elsewhere (e.g. to persist them in `/data`), set environment overrides in
the service unit with `systemctl edit fan-control.service`:
```ini
[Service]
Environment=FAN_CONTROL_TEMP_STATE_FILE=/data/fan-control/temp_state
Environment=FAN_CONTROL_OPTIMAL_PWM_FILE=/data/fan-control/optimal_pwm
Environment=FAN_CONTROL_SME_CONFIG_FILE=/data/fan-control/sme-config
```
`FAN_CONTROL_OPTIMAL_PWM_FILE` takes precedence over `OPTIMAL_PWM_FILE` in the config file.

> **Note**: The script automatically checks for missing configuration parameters and adds them with default values if they're not present in the config file. This ensures that all required parameters are always available, even if you've edited the config file manually.

If you wish to configure [SME](https://github.com/diminDDL/simple-message-exchange) telemetry, edit `/data/fan-control/sme-config`:
```bash
USE_SME_SERVER=true           # Publish telemetry to SME server (true/false)
SME_API_URL="http://192.168.0.100:8883/api/messages/publish"        # SME publish endpoint URL
SME_API_KEY="secret-api-key"  # SME API key
SME_DEVICE_ID=""              # SME device_id/topic suffix (defaults to hostname)
SME_PUBLISH_INTERVAL=60       # SME publish frequency (seconds)
```

This will then produce the following logs in the [SME](https://github.com/diminDDL/simple-message-exchange) server:
```json
{
  "message_id": "msg-UCG-Fiber-fan-state-1776110234",
  "timestamp": "2026-04-13T19:57:14Z",
  "device_id": "UCG-Fiber",
  "message_type": "telemetry",
  "service_name": "fan_state",
  "payload": {
    "controller_state": "OFF",
    "controller_pwm": 0,
    "controller_temp_smooth": 50,
    "drive_temp": null,
    "fan1_rpm": 0,
    "fan2_rpm": 0,
    "temp1": 47.7,
    "temp2": 51.4,
    "temp3": 56.1
  }
}
```

`drive_temp` is the hottest readable drive (°C), or `null` when no drive temperature
is available. If `curl` or `sensors` is missing, SME is disabled with an `ERROR` log
rather than stopping the fan controller. Successful publishes are not logged; only the
first failure of a streak and the recovery are, to stay within the journal rate limit.

Apply changes:
```bash
systemctl restart fan-control.service
```

## Operational Overview
| State       | Trigger Condition          | Exit Condition                   | Behavior                          |
|-------------|----------------------------|----------------------------------|-----------------------------------|
| **OFF**     | <65°C (60+5)               | Temp ≥ 65°C                      | Fan disabled                      |
| **TAPER**   | Temp ≤ 60°C from ACTIVE    | Temp ≥ 67°C or timer elapsed     | Minimum speed for configured mins |
| **ACTIVE**  | 65°C - 85°C                | Temp ≤ 60°C or Temp ≥ 85°C       | Quadratic speed response          |
| **EMERGENCY**| ≥85°C                     | Temp ≤ 80°C (with hysteresis)    | Immediate full speed (255 PWM)    |

### State Transitions
- **OFF → ACTIVE**: Temperature rises above activation threshold (65°C)
- **ACTIVE → TAPER**: Temperature drops below minimum threshold (60°C)
- **ACTIVE → EMERGENCY**: Temperature reaches critical level (85°C)
- **TAPER → OFF**: Cool-down period (default: 90 minutes) completes
- **TAPER → ACTIVE**: Temperature rises significantly above activation threshold (67°C, with 2°C buffer)
- **EMERGENCY → ACTIVE**: Temperature drops significantly below critical level (80°C, with 5°C hysteresis)

## Monitoring & Logging
Key operational signals:
```log
# Temperature Monitoring
TEMP: RAW=68℃ | SMOOTH=65℃ | DELTA=-3℃

# Speed Calculations
CALC: temp_diff=5℃ | range=20℃ | speed=100pwm

# State Transitions
STATE: OFF→ACTIVE (67℃ ≥ 65℃)
STATE: ACTIVE→TAPER (59℃ ≤ 60℃)
STATE: →EMERGENCY (86℃ ≥ 85℃)
STATE: EMERGENCY→ACTIVE (79℃ ≤ 80℃)
STATE: TAPER→ACTIVE (67℃ ≥ 67℃)

# Speed Changes
SET: 55→80pwm | Reason: Ramp-up limited: 55→80pwm
SET: 120→255pwm | Reason: EMERGENCY: Temp 86℃ ≥ 85℃

# Drive Temperature Floor
DRIVE: Detected /dev/nvme0n1 via nvme | Temp=47℃ | wctemp=83℃

# Enhanced Learning System
LEARNING: 80→85pwm (+5 (rising temp 2℃)) [Rate=7]
LEARNING: 95→90pwm (-5 (stable below threshold)) [Rate=5]
LEARNING: 100→99pwm (-1 (efficiency optimization)) [Rate=5]

# Error Handling
ERROR: Failed to read temperature (attempt 1)
ALERT: Multiple temperature read failures - using last known temperature
SAFETY: Activating emergency mode due to sensor failure

# Configuration Validation
CONFIG: Invalid MIN_TEMP value: 25 (should be between 30 and 80), using default: 60
CONFIG: Updating configuration file with corrected values

# Configuration Management
CONFIG: Missing parameter detected: CHECK_INTERVAL
CONFIG: Updating configuration file with 1 missing parameters
CONFIG: Configuration file updated successfully

# Deployed version
CONFIG: fan-control vX.Y.Z starting

# System Status
STATUS: State=ACTIVE | PWM=120 | Temp=72℃
STATUS: State=EMERGENCY | PWM=255 | Temp=86℃
```

View logs with:
```bash
journalctl -u fan-control.service -f          # Live monitoring
journalctl -u fan-control.service --since "10 minutes ago"  # Recent history
```

## Technical Implementation
- **Quadratic Response Curve**:

<br>

$$
PWM = MIN_{PWM} + \frac{(temp_{diff}^2 \times (MAX_{PWM} - MIN_{PWM}))}{temp_{range}^2}
$$

Where:  
`temp_diff = current_temp - activation_temp`  
`temp_range = MAX_TEMP - activation_temp`


- **Exponential Smoothing**:

<br>

$$
smoothed_{temp} = \frac{\alpha \times previous_{smooth} + (100 - \alpha) \times raw_{temp}}{100}
$$

(α configured via ALPHA parameter)

<br>


- **Enhanced Adaptive Learning**:
  - Adjusts optimal PWM based on thermal performance every 30 minutes (configurable)
  - Uses adaptive learning rate based on temperature stability
  - Implements three learning strategies:
    1. Proactive PWM increase when temperature is rising
    2. PWM reduction when temperature is stable below threshold
    3. Efficiency optimization when running faster than necessary with stable temperatures


- **Robust Error Handling**:
  - Tracks consecutive temperature reading failures
  - Implements safety measures after multiple failures
  - Uses last known temperature when readings fail
  - Activates fans proactively during sensor uncertainty

- **Configuration Validation**:
  - Validates all parameters against reasonable ranges
  - Automatically corrects invalid settings
  - Prevents misconfiguration issues

- **Hardware PWM Limitations**:  
  Due to device hardware limitations, the actual PWM values applied may differ from the requested values
  (e.g., setting 50 might result in ~48, or 100 might result in ~92)

## Maintenance
```bash
# Service Management
systemctl status fan-control.service   # Current state
systemctl restart fan-control.service  # Apply config changes

# Full Removal
/data/fan-control/uninstall.sh
```

### Which version am I running?

```bash
cat /data/fan-control/VERSION
journalctl -u fan-control.service | grep starting | tail -1
# CONFIG: fan-control v1.1.1 starting
```

Neither prints anything on builds older than v1.0.0 — those predate version identity.

### Updating

Re-run the installer. There is no auto-update: this runs as root, and a self-updating
root daemon is a large attack surface for a fan controller.

```bash
curl -fsSL https://raw.githubusercontent.com/diminDDL/unifi-fan-control/main/install.sh | sudo bash
```

**Your config is preserved.** `/data/fan-control/config` is never overwritten by an
install or upgrade — only the scripts and the service unit are replaced. No backup step
is needed.

### Does it survive a UniFi OS update?

A normal firmware update, yes. A factory reset, no.

UniFi OS runs root as an overlay: the firmware is a read-only lower layer, and anything
you install lands in the upper layer. Both halves of this install live there — the
systemd unit and `/data/fan-control` — so they share one fate. A firmware update swaps
the lower layer and leaves the upper alone.

What does remove it: factory reset, `reset2defaults`, re-adoption, or any recovery flow
that rebuilds the overlay. If the service disappears and other things you installed went
with it, that was the overlay rather than this script. Reinstall with the one-liner above.

## Project Structure
- **fan-control.sh**: The main script that monitors temperature and controls fan speed
- **VERSION**: Bare SemVer identity for the deployed daemon
- **install.sh**: Installation script that copies files and sets up the systemd service
  - Uses local runtime files first, otherwise downloads from a branch (default `main`)
- **uninstall.sh**: Script to remove the fan control system
- **fan-control.service**: Systemd service configuration
- **tests/**: Sandboxed test suite (no device, no root required); run with `tests/run-tests.sh`

## Credits & Acknowledgments
- **Thermal Research**: [UCG-Max Thermal Thread](https://www.reddit.com/r/Ubiquiti/comments/1fr8xyt/)
- **System Integration**: SierraSoftworks service patterns
- **Original Project**: [unifi-fan-control by iceteaSA](https://github.com/iceteaSA/unifi-fan-control).

---

**Disclaimer**: Community project - Not affiliated with Ubiquiti Inc.  
**Compatibility**: Verified on UniFi OS 4.0.0+ | UCG-Max, UCG-Fibre, UXG-Fibre, UDM-SE, UDM-Pro-Max, UDR7, UNVR  
**License**: MIT
