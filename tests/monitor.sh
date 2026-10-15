#!/bin/sh
# Offline integration tests: bounded monitor + incident library + fake check.
set -eu

monitor=${1:-./netguard-monitor}
library=${2:-./lib/netguard-state.sh}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

cat > "$work/fake-check" <<'MOCK'
#!/bin/sh
n=0
[ ! -r "$NETGUARD_TEST_COUNTER" ] || n=$(cat "$NETGUARD_TEST_COUNTER")
n=$((n + 1))
printf '%s\n' "$n" > "$NETGUARD_TEST_COUNTER"

case "$NETGUARD_TEST_SCENARIO" in
    wan_recovery)
        case "$n" in
            1|2|3) result=WAN_NO_L3 ;;
            4|5) result=LOCAL_DNS_UNAVAILABLE ;;
            *) result=HEALTHY_SAMPLED ;;
        esac ;;
    dns_wan)
        case "$n" in
            1|2|3) result=LOCAL_DNS_UNAVAILABLE ;;
            4|5) result=WAN_LINK_DOWN ;;
            *) result=HEALTHY_SAMPLED ;;
        esac ;;
    tool_error)
        printf 'ERROR: missing command: curl\n'
        exit 2 ;;
    missing_result)
        printf 'unexpected output with no RESULT\n'
        exit 0 ;;
    *) result=HEALTHY_SAMPLED ;;
esac
printf 'RESULT: %s\n' "$result"
case "$result" in
    HEALTHY_SAMPLED) exit 0 ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$work/fake-check"

run() {
    scenario=$1 cycles=$2
    printf '%s\n' 0 > "$work/count"
    NETGUARD_TEST_COUNTER="$work/count" \
        NETGUARD_TEST_SCENARIO="$scenario" \
        NETGUARD_CHECK_PATH="$work/fake-check" \
        NETGUARD_STATE_PATH="$library" \
        sh "$monitor" "$cycles" 0 > "$work/out"
    grep -q "^END: foreground monitor finished" "$work/out"
    [ "$(cat "$work/count")" -eq "$cycles" ]
}

run wan_recovery 7
grep -q '^OPEN 1 WAN$' "$work/out"
grep -q '^RESOLVED 1 WAN$' "$work/out"
[ "$(grep -c '^OPEN ' "$work/out")" -eq 1 ]
[ "$(grep -c '^RESOLVED ' "$work/out")" -eq 1 ]

run dns_wan 7
grep -q '^OPEN 1 DNS$' "$work/out"
grep -q '^RECLASSIFIED 1 WAN$' "$work/out"
grep -q '^RESOLVED 1 WAN$' "$work/out"

run tool_error 3
grep -q '^SAMPLE 1/3 result=PROBE_ERROR check_exit=2$' "$work/out"
grep -q '^STATE phase=UNKNOWN$' "$work/out"
if grep -q '^OPEN ' "$work/out"; then
    echo 'FAIL: internal tool error opened a network incident' >&2
    exit 1
fi

run missing_result 3
grep -q '^SAMPLE 1/3 result=PROBE_ERROR check_exit=0$' "$work/out"
if grep -q '^OPEN ' "$work/out"; then
    echo 'FAIL: missing RESULT opened a network incident' >&2
    exit 1
fi

# No implicit infinite mode and no accidental zero-interval background daemon.
if sh "$monitor" 0 0 >"$work/out" 2>&1; then
    echo 'FAIL: zero cycles accepted' >&2
    exit 1
fi

printf 'PASS: bounded monitor integration (WAN/DNS correlation, recovery, probe errors)\n'
