#!/bin/sh
# Offline smoke tests; do not require OpenWrt or network access.
set -eu

script=${1:-./owrt-netguard}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

cat > "$work/ubus" <<'MOCK'
#!/bin/sh
if [ "${NETGUARD_TEST_SCENARIO:-}" = wan_no_l3 ]; then
    printf '%s\n' '{"up":false,"device":"wan"}'
else
    printf '%s\n' '{"up":true,"l3_device":"wan","device":"wan"}'
fi
MOCK

cat > "$work/jsonfilter" <<'MOCK'
#!/bin/sh
while [ "$#" -gt 0 ]; do
    if [ "$1" = '-e' ]; then key=$2; shift 2; else shift; fi
done
case "$key" in
    '@.up') echo true ;;
    '@.l3_device') [ "${NETGUARD_TEST_SCENARIO:-}" = wan_no_l3 ] || echo wan ;;
    '@.device') echo wan ;;
esac
MOCK

cat > "$work/ip" <<'MOCK'
#!/bin/sh
if [ "${NETGUARD_TEST_SCENARIO:-}" = bad_route ]; then
    echo '1.1.1.1 dev awg0 src 10.10.0.1'
else
    echo '1.1.1.1 via 192.0.2.1 dev wan src 192.0.2.2'
fi
MOCK

cat > "$work/nft" <<'MOCK'
#!/bin/sh
exit 1
MOCK

cat > "$work/curl" <<'MOCK'
#!/bin/sh
case "${NETGUARD_TEST_SCENARIO:-}" in
    no_https) echo 000; exit 7 ;;
    http_restricted) echo 403; exit 0 ;;
    one_good)
        case "$*" in
            *one.one.one.one*) echo 200 ;;
            *safe.dot.dns.yandex.net*) echo 404 ;;
            *dns.quad9.net*) echo 404 ;;
            *dns.google*) echo 451 ;;
            *) echo 000; exit 7 ;;
        esac ;;
    *)
        case "$*" in
            *safe.dot.dns.yandex.net*) echo 404 ;;
            *) echo 200 ;;
        esac ;;
esac
MOCK

cat > "$work/nslookup" <<'MOCK'
#!/bin/sh
for last do :; done
if [ "${NETGUARD_TEST_SCENARIO:-}" = local_dns_down ] && [ "$last" = 127.0.0.1 ]; then
    exit 1
fi
if [ "${NETGUARD_TEST_SCENARIO:-}" = no_dns ]; then
    exit 1
fi
if [ "${NETGUARD_TEST_SCENARIO:-}" = external_dns_down ] && [ "$last" != 127.0.0.1 ]; then
    exit 1
fi
printf 'Name: example.com\nAddress: 93.184.215.14\n'
MOCK

cat > "$work/timeout" <<'MOCK'
#!/bin/sh
echo 'The external timeout utility must not be used' >&2
exit 80
MOCK

chmod +x "$work"/*

run() {
    name=$1 expected=$2
    set +e
    output=$(PATH="$work:$PATH" NETGUARD_TEST_SCENARIO="$name" sh "$script" check 2>&1)
    rc=$?
    set -e

    printf '%s\n' "$output" | grep -q "RESULT: $expected" || {
        printf 'FAIL %s (exit %s):\n%s\n' "$name" "$rc" "$output"
        exit 1
    }
    # Guard the original regression: HTTP 404 must not count as a healthy endpoint.
    case "$name" in
        healthy)
            printf '%s\n' "$output" | grep -q 'HTTPS yandex.*TRANSPORT_ONLY (HTTP 404' || exit 1
            printf '%s\n' "$output" | grep -q 'HTTPS healthy=2' || exit 1 ;;
        one_good)
            printf '%s\n' "$output" | grep -q 'HTTPS healthy=1' || exit 1
            printf '%s\n' "$output" | grep -q 'HTTPS quad9.*UNEXPECTED (HTTP 404' || exit 1 ;;
    esac

    if [ "$expected" = HEALTHY_SAMPLED ]; then expected_rc=0; else expected_rc=1; fi
    [ "$rc" -eq "$expected_rc" ] || {
        printf 'FAIL %s: unexpected exit code %s (wanted %s)\n%s\n' "$name" "$rc" "$expected_rc" "$output"
        exit 1
    }
    printf 'PASS %s -> %s (exit %s)\n' "$name" "$expected" "$rc"
}

run healthy HEALTHY_SAMPLED
run local_dns_down LOCAL_DNS_UNAVAILABLE
run bad_route UNKNOWN_ROUTE
run no_https PARTIAL_REACHABILITY
run no_dns DNS_PATH_UNCONFIRMED
run http_restricted PARTIAL_REACHABILITY
run one_good PARTIAL_REACHABILITY
run external_dns_down EXTERNAL_DNS_UNCONFIRMED
run wan_no_l3 WAN_NO_L3
