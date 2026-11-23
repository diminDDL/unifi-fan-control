#!/bin/bash
###############################################################################
# Link-speed PWM floor: a fast link on LINK_FLOOR_INTERFACE holds a minimum PWM
###############################################################################
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_DIR/lib/harness.sh"
trap teardown_sandbox EXIT

declare -i scenario=0

# set_link <iface> <operstate> <speed>
set_link() {
    local dir="$FAN_CONTROL_NET_CLASS_DIR/$1"
    mkdir -p "$dir"
    echo "$2" >"$dir/operstate"
    if [[ "$2" == "up" ]]; then echo 1 >"$dir/carrier"; else echo 0 >"$dir/carrier"; fi
    echo "$3" >"$dir/speed"
}

# write_link_config <iface> <speed> <pwm>; the daemon appends the other params
write_link_config() {
    cat >"$FAN_CONTROL_CONFIG_FILE" <<CFG
LINK_FLOOR_INTERFACE="$1"
LINK_FLOOR_SPEED=$2
LINK_FLOOR_PWM=$3
CFG
}

# ── Scenario 1: cool device, 10G link up → fan held at the floor ─────────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
set_link eth9 up 10000
write_link_config eth9 10000 128

start_daemon
wait_for_log "LINK: eth9 up at 10000Mb/s" 5
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "128" 10
echo "  ✓ Scenario ${scenario}: OFF state lifted to 128pwm by a 10G link"

# ── Scenario 2: link renegotiates to 1G → floor released, fan stops ─────────
scenario=$((scenario + 1))
set_link eth9 up 1000
wait_for_log "LINK: eth9 up at 1000Mb/s" 5
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "0" 10
echo "  ✓ Scenario ${scenario}: floor released when the link drops below 10G"

# ── Scenario 3: link goes down → no floor, logged once ───────────────────────
scenario=$((scenario + 1))
set_link eth9 down -1
wait_for_log "LINK: eth9 down" 5
/bin/sleep 1
assert_eq "$(grep -c 'LINK: eth9 down' "$SANDBOX/syslog")" "1" "link-down log count: "
assert_eq "$(get_pwm)" "0" "PWM with link down: "
echo "  ✓ Scenario ${scenario}: link down logged once, fan stays off"
stop_daemon
cleanup_sandbox

# ── Scenario 4: ACTIVE inside the deadband still picks up a new floor ────────
scenario=$((scenario + 1))
setup_sandbox
echo "70" >"$SANDBOX/cputemp"
set_link eth9 down -1
write_link_config eth9 10000 250

start_daemon
wait_for_log "SET:" 10
/bin/sleep 1
before=$(get_pwm)
((before < 250)) || fail "ACTIVE PWM already at floor before link came up ($before)"
set_link eth9 up 10000
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "250" 10
echo "  ✓ Scenario ${scenario}: ACTIVE ${before}pwm raised to 250pwm floor despite stable temp"
stop_daemon
cleanup_sandbox

# ── Scenario 5: missing interface is reported once and changes nothing ───────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
write_link_config eth42 10000 128

start_daemon
wait_for_log "LINK: eth42 not found or unreadable" 5
/bin/sleep 1
daemon_alive || fail "daemon died with a missing link interface"
assert_eq "$(grep -c 'LINK:' "$SANDBOX/syslog")" "1" "missing-interface log count: "
assert_eq "$(get_pwm)" "0" "PWM with missing interface: "
echo "  ✓ Scenario ${scenario}: missing interface logged once, fan unaffected"
stop_daemon
cleanup_sandbox

# ── Scenario 6: path-like interface names are rejected ───────────────────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
write_link_config "../../etc" 10000 128

start_daemon
wait_for_log "Invalid LINK_FLOOR_INTERFACE" 5
grep -q '^LINK_FLOOR_INTERFACE=""' "$FAN_CONTROL_CONFIG_FILE" ||
    fail "invalid interface was not reset in the config file"
echo "  ✓ Scenario ${scenario}: path-like interface name rejected and cleared"
stop_daemon
cleanup_sandbox

# ── Scenarios 7-9: swconfig switch port (UCG-Fiber 10GBASE-T is switch0 port 0)
# Stub mirrors real UCG-Fiber output of `swconfig dev switch0 port N get link`.
install_swconfig_stub() {
    cat >"$SANDBOX/bin/swconfig" <<STUB
#!/usr/bin/env bash
[[ "\$1 \$3 \$5 \$6" == "dev port get link" ]] || exit 2
[[ "\$2" == "switch0" ]] || exit 1
cat "$SANDBOX/swport\$4" 2>/dev/null || exit 1
STUB
    chmod +x "$SANDBOX/bin/swconfig"
}

scenario=$((scenario + 1))
setup_sandbox
install_swconfig_stub
echo "45" >"$SANDBOX/cputemp"
# Every ethN reports a fixed 10G uplink on this hardware; it must be ignored.
set_link eth0 up 10000
echo "port:0 link:down" >"$SANDBOX/swport0"
echo "port:1 link:up speed:10000baseT full-duplex txflow rxflow auto" >"$SANDBOX/swport1"
write_link_config "swconfig:switch0:0" 10000 128

start_daemon
wait_for_log "LINK: swconfig:switch0:0 down" 5
/bin/sleep 1
assert_eq "$(get_pwm)" "0" "PWM with swconfig port down: "
echo "  ✓ Scenario ${scenario}: swconfig port 0 down → no floor (other ports ignored)"

scenario=$((scenario + 1))
echo "port:0 link:up speed:10000baseT full-duplex txflow rxflow auto" >"$SANDBOX/swport0"
wait_for_log "LINK: swconfig:switch0:0 up at 10000Mb/s" 5
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "128" 10
echo "  ✓ Scenario ${scenario}: swconfig port 0 at 10G → 128pwm floor"

scenario=$((scenario + 1))
echo "port:0 link:up speed:2500baseT full-duplex txflow rxflow auto" >"$SANDBOX/swport0"
wait_for_log "LINK: swconfig:switch0:0 up at 2500Mb/s" 5
wait_for_file_value "$SANDBOX/hwmon/hwmon0/pwm1" "0" 10
echo "  ✓ Scenario ${scenario}: swconfig port 0 at 2.5G → floor released"
stop_daemon
cleanup_sandbox

# ── Scenario 10: swconfig source unavailable is reported, not fatal ──────────
scenario=$((scenario + 1))
setup_sandbox
install_swconfig_stub
echo "45" >"$SANDBOX/cputemp"
write_link_config "swconfig:switch9:0" 10000 128

start_daemon
wait_for_log "LINK: swconfig:switch9:0 not found or unreadable" 5
/bin/sleep 1
daemon_alive || fail "daemon died with an unreadable swconfig port"
assert_eq "$(get_pwm)" "0" "PWM with unreadable swconfig port: "
echo "  ✓ Scenario ${scenario}: unreadable swconfig port logged, fan unaffected"
stop_daemon
cleanup_sandbox

# ── Scenario 11: disabled by default → no LINK activity ──────────────────────
scenario=$((scenario + 1))
setup_sandbox
echo "45" >"$SANDBOX/cputemp"
set_link eth9 up 10000

start_daemon
/bin/sleep 1.5
if grep -q "LINK:" "$SANDBOX/syslog"; then
    fail "link floor active without LINK_FLOOR_INTERFACE configured"
fi
assert_eq "$(get_pwm)" "0" "PWM with link floor disabled: "
echo "  ✓ Scenario ${scenario}: disabled by default"
stop_daemon
cleanup_sandbox

echo "  All ${scenario} link floor scenarios passed."
