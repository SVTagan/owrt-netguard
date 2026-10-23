#!/bin/sh
# Offline, network-free WAN path evidence tests.
set -eu

audit=${1:-./netguard-path-audit}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

cat > "$work/ubus" <<'MOCK'
#!/bin/sh
printf '%s\n' '{"up":true,"l3_device":"wan"}'
MOCK
cat > "$work/jsonfilter" <<'MOCK'
#!/bin/sh
case "$*" in
    *'@.up'*) case "$NETGUARD_TEST_SCENARIO" in down) echo false ;; *) echo true ;; esac ;;
    *'@.l3_device'*) echo wan ;;
esac
MOCK
cat > "$work/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    *'route get '*)
        case "$NETGUARD_TEST_SCENARIO" in
            other_route) echo '1.1.1.1 dev awg0 src 10.0.0.2' ;;
            no_route) exit 2 ;;
            *) echo '1.1.1.1 via 192.0.2.1 dev wan src 192.0.2.2' ;;
        esac ;;
    *'rule show')
        cat <<EOF
0:      from all lookup local
32766:  from all lookup main
32767:  from all lookup default
EOF
        case "$NETGUARD_TEST_SCENARIO" in
            policy) echo '100: from all fwmark 0x100 lookup 100' ;;
        esac ;;
    *) exit 2 ;;
esac
MOCK
cat > "$work/nft" <<'MOCK'
#!/bin/sh
case "$NETGUARD_TEST_SCENARIO" in
    nft_error) exit 2 ;;
    nft_route) echo 'chain route_output { type route hook output priority mangle; policy accept; }' ;;
    nft_nat) echo 'chain dstnat_output { type nat hook output priority dstnat; policy accept; }' ;;
    *) echo 'chain output { type filter hook output priority filter; policy accept; }' ;;
esac
MOCK
chmod +x "$work/ubus" "$work/jsonfilter" "$work/ip" "$work/nft"

run() {
    scenario=$1
    expected=$2
    NETGUARD_TEST_SCENARIO="$scenario" PATH="$work:$PATH" \
        sh "$audit" > "$work/out"
    grep -qx "PATH_AUDIT: $expected" "$work/out"
    grep -q '^NOTE: neither interface binding' "$work/out"
}

run healthy ROUTE_MATCH_ONLY
grep -qx 'IPV4_POLICY_RULES: DEFAULT_ONLY' "$work/out"
grep -qx 'NFT_ROUTE_OUTPUT_HOOK: NO' "$work/out"
run policy ROUTE_MATCH_ONLY
grep -qx 'IPV4_POLICY_RULES: ADDITIONAL_RULES' "$work/out"
run nft_route ROUTE_MATCH_ONLY
grep -qx 'NFT_ROUTE_OUTPUT_HOOK: YES' "$work/out"
run nft_nat ROUTE_MATCH_ONLY
grep -qx 'NFT_NAT_OUTPUT_HOOK: YES' "$work/out"
run nft_error ROUTE_MATCH_ONLY
grep -qx 'NFT_ROUTE_OUTPUT_HOOK: UNKNOWN' "$work/out"
run other_route ROUTE_MISMATCH
run no_route INSUFFICIENT_EVIDENCE
run down INSUFFICIENT_EVIDENCE
grep -qx 'ROUTE_UNMARKED: WAN_NOT_READY' "$work/out"

if NETGUARD_TEST_SCENARIO=healthy PATH="$work:$PATH" sh "$audit" 'not-an-ip' > "$work/out" 2>&1; then
    echo 'FAIL: accepted invalid target' >&2
    exit 1
fi
if NETGUARD_TEST_SCENARIO=healthy OWRT_NETGUARD_WAN='wan;echo hacked' PATH="$work:$PATH" sh "$audit" > "$work/out" 2>&1; then
    echo 'FAIL: accepted unsafe WAN name' >&2
    exit 1
fi
printf 'PASS: WAN path audit evidence, policy/nft uncertainty and invalid arguments\n'
