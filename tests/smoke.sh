#!/bin/sh
# Offline smoke tests; do not require OpenWrt or network access.
set -eu

script=${1:-./owrt-netguard}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/config" "$work/empty"
: > "$work/config/netguard"

cat > "$work/uci" <<'MOCK'
#!/bin/sh
for last do :; done
case "${NETGUARD_TEST_SCENARIO:-}" in
    custom_pool|custom_partial|custom_dns|invalid_https|invalid_ipv4)
        case "$*" in
            *"show netguard") exit 0 ;;
            *"get netguard.main.https")
                case "${NETGUARD_TEST_SCENARIO:-}" in
                    custom_pool) echo 'my_cf|1.1.1.1|one.one.one.one|/cdn-cgi/trace|200 my_google|8.8.8.8|dns.google|/resolve?name=example.com&type=A|200' ;;
                    custom_partial) echo 'portal|203.0.113.1|portal.example|/|200' ;;
                    invalid_https) echo 'bad|1.1.1.1|one.one.one.one|wrong-path|200' ;;
                    invalid_ipv4) echo 'bad|1.2.3.4.|example.com|/|200' ;;
                    *) exit 1 ;;
                esac ;;
            *"get netguard.main.dns")
                case "${NETGUARD_TEST_SCENARIO:-}" in
                    custom_dns) echo 'only_custom|1.1.1.1 other_custom|8.8.8.8' ;;
                    *) exit 1 ;;
                esac ;;
        esac ;;
    invalid_uci)
        case "$*" in *"show netguard") exit 1 ;; esac ;;
esac
exit 1
MOCK

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
    case "$name" in
        custom_pool|custom_partial|custom_dns|invalid_https|invalid_ipv4|invalid_uci)
            config_dir="$work/config" ;;
        *) config_dir="$work/empty" ;;
    esac
    output=$(PATH="$work:$PATH" OWRT_NETGUARD_CONFIG_DIR="$config_dir" NETGUARD_TEST_SCENARIO="$name" sh "$script" check 2>&1)
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
            printf '%s\n' "$output" | grep -q 'HTTPS google.*UNEXPECTED (HTTP 451' || exit 1 ;;
        custom_pool)
            printf '%s\n' "$output" | grep -q 'Endpoints: HTTPS=2 (uci)' || exit 1
            printf '%s\n' "$output" | grep -q 'HTTPS my_cf' || exit 1 ;;
        custom_dns)
            printf '%s\n' "$output" | grep -q 'external DNS=2 (uci)' || exit 1
            printf '%s\n' "$output" | grep -q 'DNS   only_custom' || exit 1 ;;
        custom_partial)
            printf '%s\n' "$output" | grep -q 'HTTPS portal' || exit 1 ;;
        invalid_https|invalid_ipv4|invalid_uci)
            printf '%s\n' "$output" | grep -q 'ERROR:' || exit 1 ;;
    esac

    case "$expected" in
        HEALTHY_SAMPLED) expected_rc=0 ;;
        CONFIG_ERROR) expected_rc=2 ;;
        *) expected_rc=1 ;;
    esac
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
run custom_pool HEALTHY_SAMPLED
run custom_dns HEALTHY_SAMPLED
run custom_partial PARTIAL_REACHABILITY
run invalid_https CONFIG_ERROR
run invalid_ipv4 CONFIG_ERROR
run invalid_uci CONFIG_ERROR
