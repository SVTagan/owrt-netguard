#!/bin/sh
# Offline tests for the experimental RAM-only continuous worker.
# No services are started and no real DNS/HTTPS probes are performed.
set -eu

worker=${1:-./netguard-worker}
library=${2:-./lib/netguard-state.sh}
tmp=$(mktemp -d /tmp/netguard-worker-tests.XXXXXX)
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat > "$tmp/fake-check" <<'MOCK'
#!/bin/sh
n=0
[ ! -f "$NETGUARD_TEST_COUNTER" ] || n=$(cat "$NETGUARD_TEST_COUNTER")
n=$((n + 1))
printf '%s\n' "$n" > "$NETGUARD_TEST_COUNTER"

case "$NETGUARD_TEST_SCENARIO" in
    outage_then_recovery)
        case "$n" in
            1|2|3) result=WAN_NO_L3 ;;
            *) result=HEALTHY_SAMPLED ;;
        esac ;;
    internal_failure)
        printf 'ERROR: deliberately simulated missing dependency\n'
        exit 2 ;;
    startup_failure) result=WAN_NO_L3 ;;
    netifd_pending) result=WAN_INITIALIZING ;;
    healthy_then_fault)
        if [ "$n" -eq 1 ]; then
            result=HEALTHY_SAMPLED
        else
            result=WAN_NO_L3
        fi ;;
    *) result=HEALTHY_SAMPLED ;;
esac
printf 'RESULT: %s\n' "$result"
case "$result" in
    HEALTHY_SAMPLED) exit 0 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$tmp/fake-check"

run() {
    scenario=$1
    cycles=$2
    grace=${3:-0}
    interval=${4:-0}
    mkdir -p "$tmp/$scenario"
    printf '0\n' > "$tmp/counter"
    NETGUARD_STARTUP_GRACE="$grace" \
    NETGUARD_TEST_COUNTER="$tmp/counter" \
    NETGUARD_TEST_SCENARIO="$scenario" \
    NETGUARD_CHECK_PATH="$tmp/fake-check" \
    NETGUARD_STATE_PATH="$library" \
    NETGUARD_RUNTIME_DIR="$tmp/$scenario" \
        sh "$worker" --cycles "$cycles" "$interval" > "$tmp/$scenario.log"
    [ "$(cat "$tmp/counter")" -eq "$cycles" ]
    [ -f "$tmp/$scenario/status" ]
    grep -qx 'running=0' "$tmp/$scenario/status"
    grep -qx "cycle=$cycles" "$tmp/$scenario/status"
}

run outage_then_recovery 5
grep -qx 'OPEN 1 WAN' "$tmp/outage_then_recovery.log"
grep -qx 'RESOLVED 1 WAN' "$tmp/outage_then_recovery.log"
grep -qx 'phase=HEALTHY' "$tmp/outage_then_recovery/status"
grep -qx 'result=HEALTHY_SAMPLED' "$tmp/outage_then_recovery/status"

# An initial WAN failure is visible but cannot open an incident during grace.
run startup_failure 5 90
grep -qx 'phase=STARTUP' "$tmp/startup_failure/status"
grep -qx 'result=STARTUP_WAIT' "$tmp/startup_failure/status"
grep -qx 'observed_result=WAN_NO_L3' "$tmp/startup_failure/status"
grep -qx 'startup_grace_s=90' "$tmp/startup_failure/status"
if grep -q '^OPEN ' "$tmp/startup_failure.log"; then
    echo 'FAIL: startup grace opened a premature incident' >&2
    exit 1
fi

# The same failure must become a WAN incident with grace disabled.
run startup_failure 3 0
grep -qx 'OPEN 1 WAN' "$tmp/startup_failure.log"
grep -qx 'phase=OPEN' "$tmp/startup_failure/status"

# netifd pending setup is not a confirmed outage during grace.
run netifd_pending 3 90
grep -qx 'phase=STARTUP' "$tmp/netifd_pending/status"
grep -qx 'observed_result=WAN_INITIALIZING' "$tmp/netifd_pending/status"

# A WAN still pending after deadline becomes a diagnosable missing-L3 fault.
run netifd_pending 3 0
grep -qx 'OPEN 1 WAN' "$tmp/netifd_pending.log"
grep -qx 'result=WAN_NO_L3' "$tmp/netifd_pending/status"
grep -qx 'observed_result=WAN_INITIALIZING' "$tmp/netifd_pending/status"

# Wall-clock-independent monotonic deadline: setup may not remain STARTUP
# indefinitely. The deadline uses /proc/uptime and becomes WAN_NO_L3.
run netifd_pending 4 1 1
grep -qx 'OPEN 1 WAN' "$tmp/netifd_pending.log"
grep -qx 'phase=OPEN' "$tmp/netifd_pending/status"

# A first confirmed healthy sample ends startup grace immediately;
# subsequent WAN loss must not be hidden behind another 90-second wait.
run healthy_then_fault 4 90
grep -qx 'OPEN 1 WAN' "$tmp/healthy_then_fault.log"
grep -qx 'phase=OPEN' "$tmp/healthy_then_fault/status"

run internal_failure 3
grep -qx 'phase=UNKNOWN' "$tmp/internal_failure/status"
grep -qx 'result=PROBE_ERROR' "$tmp/internal_failure/status"
if grep -q '^OPEN' "$tmp/internal_failure.log"; then
    echo 'FAIL: technical error was classified as an incident' >&2
    exit 1
fi

# Invalid arguments must not silently enable an endless loop.
if sh "$worker" --cycles 0 10 >/dev/null 2>&1; then
    echo 'FAIL: bounded zero-cycle mode accepted' >&2
    exit 1
fi
if sh "$worker" --forever 0 >/dev/null 2>&1; then
    echo 'FAIL: unsafe endless zero-delay mode accepted' >&2
    exit 1
fi
if NETGUARD_STARTUP_GRACE=301 sh "$worker" --cycles 1 0 >/dev/null 2>&1; then
    echo 'FAIL: startup grace beyond safe range accepted' >&2
    exit 1
fi

# Reject persistent state directories.
if NETGUARD_RUNTIME_DIR=/etc/netguard \
    NETGUARD_CHECK_PATH="$tmp/fake-check" \
    NETGUARD_STATE_PATH="$library" \
    sh "$worker" --cycles 1 0 >/dev/null 2>&1; then
    echo 'FAIL: persistent runtime location accepted' >&2
    exit 1
fi

echo 'PASS: worker transitions, bounded startup grace, pending WAN, RAM snapshot and safe invocation limits'
