#!/bin/bash
###############################################################################
# Fork features: external PWM override correction and SME telemetry publishing
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

install_sme_stubs() {
    local curl_exit="$1"
    cat >"$SANDBOX/bin/sensors" <<'STUB'
#!/usr/bin/env bash
cat <<'OUT'
fan1:        1500 RPM
fan2:        1480 RPM
temp1:        +47.7°C
temp2:        +51.4°C
temp3:        +56.1°C
OUT
STUB
    # curl stub: records the -d body and exits with the requested status
    cat >"$SANDBOX/bin/curl" <<STUB
#!/usr/bin/env bash
while [[ \$# -gt 0 ]]; do
    if [[ "\$1" == "-d" ]]; then
        printf '%s\n' "\$2" >>"$SANDBOX/sme-bodies"
        echo "---" >>"$SANDBOX/sme-bodies"
    fi
    shift
done
exit $curl_exit
STUB
    chmod +x "$SANDBOX/bin/sensors" "$SANDBOX/bin/curl"
}

write_sme_config() {
    cat >"$FAN_CONTROL_SME_CONFIG_FILE" <<'CFG'
USE_SME_SERVER=true
SME_API_URL="http://sme.invalid/api/messages/publish"
SME_API_KEY="k"
SME_DEVICE_ID="test-device"
SME_PUBLISH_INTERVAL=10
CFG
}

# ── Scenario 1: external PWM change is reverted and logged once ──────────────
setup_sandbox
echo "75" >"$SANDBOX/cputemp"
start_daemon
wait_for_log "SET:" 10
/bin/sleep 0.5
controlled_pwm=$(get_pwm)
((controlled_pwm > 0)) || fail "expected an active PWM, got $controlled_pwm"

echo 7 >"$SANDBOX/hwmon/hwmon0/pwm1"
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "$controlled_pwm" 10
wait_for_log "OVERRIDE: External PWM change detected" 5
wait_for_log "OVERRIDE: External PWM changes stopped" 5
echo "  ✓ Scenario 1: external PWM change reverted to ${controlled_pwm}pwm"
stop_daemon
cleanup_sandbox

# ── Scenario 2: unchanged PWM never triggers a correction ───────────────────
setup_sandbox
echo "75" >"$SANDBOX/cputemp"
start_daemon
/bin/sleep 3
if grep -q "OVERRIDE:" "$SANDBOX/syslog"; then
    fail "override correction fired without an external change"
fi
echo "  ✓ Scenario 2: no spurious override corrections"
stop_daemon
cleanup_sandbox

# ── Scenario 3: SME publishes valid JSON without logging success ─────────────
setup_sandbox
install_sme_stubs 0
write_sme_config
echo "45" >"$SANDBOX/cputemp"
start_daemon
for _ in $(seq 1 50); do
    [[ -s "$SANDBOX/sme-bodies" ]] && break
    /bin/sleep 0.1
done
[[ -s "$SANDBOX/sme-bodies" ]] || fail "no SME publish recorded"
body=$(awk '/^---$/ {exit} {print}' "$SANDBOX/sme-bodies")
if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json,sys; d=json.loads(sys.argv[1]); p=d["message"]["payload"]; assert p["fan1_rpm"]==1500 and p["temp3"]==56.1 and p["controller_state"]=="OFF", p' "$body" ||
        fail "SME body is not the expected JSON: $body"
fi
assert_contains "$body" '"topic": "devices/test-device/telemetry/fan_state"'
if grep -q "SME:" "$SANDBOX/syslog"; then
    fail "successful SME publish should not be logged"
fi
echo "  ✓ Scenario 3: SME telemetry published as JSON, success not logged"
stop_daemon
cleanup_sandbox

# ── Scenario 4: SME failure is logged once and does not stop the daemon ─────
setup_sandbox
install_sme_stubs 7
write_sme_config
echo "45" >"$SANDBOX/cputemp"
start_daemon
wait_for_log "SME: Publish to" 5
/bin/sleep 1
daemon_alive || fail "daemon died after SME failure"
assert_eq "$(grep -c 'SME:' "$SANDBOX/syslog")" "1" "SME failure log count: "
echo "  ✓ Scenario 4: SME failure logged once, daemon keeps running"
stop_daemon
cleanup_sandbox
