#!/bin/sh
# Offline test of experimental grouped HTTPS profile probe.
set -eu
script=${1:-./netguard-profile-probe}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin"

cat > "$work/mock-profiles.sh" <<'MOCK'
ng_profiles_load() {
    NG_PROFILE_SELECTED=${1:-russia}
    NG_PROFILE_SOURCE=mock
    case "${NG_TEST_MODE:-}" in
        legacy) NG_PROFILE_SELECTED=legacy ;;
        invalid) return 2 ;;
    esac
    case "$NG_PROFILE_SELECTED" in
        russia)
            NG_PROFILE_TARGETS='ru_diverse|selectel|selectel.ru|auto|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|auto|/robots.txt|200|User-agent
international|google|www.gstatic.com|auto|/generate_204|204|-'
            case "${NG_TEST_MODE:-}" in
                allowlist) NG_PROFILE_TARGETS='ru_base|base|ya.ru|auto|/health|200|User-agent
ru_diverse|selectel|selectel.ru|auto|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|auto|/robots.txt|200|User-agent' ;;
                pinned|dns_fail) NG_PROFILE_TARGETS='ru_diverse|selectel|selectel.ru|192.0.2.5|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|auto|/robots.txt|200|User-agent' ;;
                pinned_mismatch) NG_PROFILE_TARGETS='ru_diverse|selectel|selectel.ru|203.0.113.5|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|auto|/robots.txt|200|User-agent' ;;
            esac
            ;;
        international)
            NG_PROFILE_TARGETS='international|google|www.gstatic.com|auto|/generate_204|204|-
international|apple|captive.apple.com|auto|/hotspot-detect.html|200|Success'
            ;;
        custom)
            NG_PROFILE_TARGETS='ru_diverse|selectel|selectel.ru|auto|/robots.txt|200|User-agent'
            ;;
    esac
    NG_PROFILE_COUNT=$(printf '%s\n' "$NG_PROFILE_TARGETS" | wc -l)
}
MOCK

cat > "$work/bin/ubus" <<'MOCK'
#!/bin/sh
printf '%s\n' '{"up":true,"l3_device":"wan"}'
MOCK
cat > "$work/bin/jsonfilter" <<'MOCK'
#!/bin/sh
case "$*" in
    *'@.up'*) [ "${NG_TEST_MODE:-}" = wan_down ] && echo false || echo true ;;
    *'@.l3_device'*) echo wan ;;
esac
MOCK
cat > "$work/bin/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    *203.0.113.5*) echo '203.0.113.5 dev awg0' ;;
    *198.51.100.5*) echo '198.51.100.5 dev awg0' ;;
    *) echo '192.0.2.5 via 192.0.2.1 dev wan src 192.0.2.2' ;;
esac
MOCK
cat > "$work/bin/curl" <<'MOCK'
#!/bin/sh
out=
url=
resolve=
interface=
noproxy=
proto=
maxsize=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out=$2; shift 2 ;;
        --resolve) resolve=$2; shift 2 ;;
        --interface) interface=$2; shift 2 ;;
        --noproxy) noproxy=$2; shift 2 ;;
        --proto) proto=$2; shift 2 ;;
        --max-filesize) maxsize=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
[ "$interface" = 'if!wan' ] && [ "$noproxy" = '*' ] && [ "$proto" = '=https' ] && [ "$maxsize" = 32768 ] || exit 95
if { [ "${NG_TEST_MODE:-}" = pinned ] || [ "${NG_TEST_MODE:-}" = dns_fail ]; } && [ "$url" = 'https://selectel.ru/robots.txt' ]; then
    [ "$resolve" = 'selectel.ru:443:192.0.2.5' ] || exit 96
fi
case "$url" in
    *selectel.ru*) name=selectel ;;
    *timeweb.com*) name=timeweb ;;
    *gstatic.com*) name=google ;;
    *ya.ru*) name=base ;;
    *captive.apple.com*) name=apple ;;
    *) name=unknown ;;
esac
case "${NG_TEST_MODE:-}:$name" in
    blocked_international:google|all_fail:*|allowlist:selectel|allowlist:timeweb|partial:timeweb|intl_blocked:*)
        printf '000|-|0|4.000|0'; exit 28 ;;
    dns_fail:timeweb|dns_fail:google)
        printf '000|-|-|0.000|0'; exit 6 ;;
    tls_failure:timeweb)
        printf '000|-|18|0.200|0'; exit 60 ;;
    wrong_body:timeweb)
        [ "$out" = /dev/null ] || printf 'not-matching' > "$out"
        printf '200|192.0.2.6|0|0.200|12'; exit 0 ;;
    redirect:selectel)
        printf '302|192.0.2.5|0|0.200|0'; exit 0 ;;
    path_mismatch:timeweb)
        [ "$out" = /dev/null ] || printf 'User-agent' > "$out"
        printf '200|198.51.100.5|0|0.200|10'; exit 0 ;;
    body_limit:timeweb)
        printf '200|192.0.2.6|0|0.200|32768'; exit 63 ;;
    *) ;;
esac
if [ "$name" = apple ]; then
    [ "$out" = /dev/null ] || printf 'Success' > "$out"
    printf '200|192.0.2.8|0|0.200|7'
elif [ "$name" = google ]; then
    printf '204|192.0.2.7|0|0.200|0'
else
    [ "$out" = /dev/null ] || printf 'User-agent' > "$out"
    printf '200|192.0.2.5|0|0.200|10'
fi
MOCK
chmod +x "$work/bin"/*

run() {
    NG_TEST_MODE=${1:-} PATH="$work/bin:$PATH" NETGUARD_PROFILES_LIB="$work/mock-profiles.sh" \
        sh "$script" --profile "${2:-russia}" > "$work/out" 2> "$work/err"
}
assert() {
    grep -Fq -- "$1" "$work/out" || { printf 'FAIL: missing %s\n' "$1" >&2; cat "$work/out" >&2; exit 1; }
}

run blocked_international
assert 'PROFILE_OBSERVATION: RU_REACHABLE_SAMPLED'
assert 'GROUP ru_diverse targets=2 matched=2'
assert 'GROUP international targets=1 matched=0'
assert 'INTERNATIONAL_UNCONFIRMED'
! grep -q '^RESULT:' "$work/out"

run allowlist
assert 'PROFILE_OBSERVATION: POSSIBLE_LIMITED_ACCESS'
assert 'GROUP ru_base targets=1 matched=1'
run partial
assert 'PROFILE_OBSERVATION: RU_PARTIALLY_CONFIRMED'
run all_fail
assert 'PROFILE_OBSERVATION: RU_ACCESS_UNCONFIRMED'
run wrong_body
assert 'result=CONTRACT_MISMATCH'
assert 'PROFILE_OBSERVATION: RU_PARTIALLY_CONFIRMED'
run redirect
assert 'result=REDIRECT'
assert 'PROFILE_OBSERVATION: RU_PARTIALLY_CONFIRMED'
run path_mismatch
assert 'result=PATH_UNCONFIRMED'
assert 'GROUP ru_diverse targets=2 matched=1'
run body_limit
assert 'result=BODY_LIMIT'
assert 'PROFILE_OBSERVATION: RU_PARTIALLY_CONFIRMED'
run pinned
assert 'dns=PINNED result=MATCHED'
run dns_fail
assert 'dns=PINNED result=MATCHED'
assert 'dns=SYSTEM result=DNS_FAILED'
assert 'PROFILE_OBSERVATION: RU_PARTIALLY_CONFIRMED'
run tls_failure
assert 'dns=SYSTEM result=TLS_FAILED'
run pinned_mismatch
assert 'result=SKIPPED_ROUTE route_unmarked=OTHER_DEVICE'
assert 'PROFILE_OBSERVATION: RU_PARTIALLY_CONFIRMED'
run intl_blocked international
assert 'PROFILE_OBSERVATION: INTERNATIONAL_UNCONFIRMED'
run normal international
assert 'PROFILE_OBSERVATION: INTERNATIONAL_REACHABLE_SAMPLED'
run redirect custom
assert 'PROFILE_OBSERVATION: TRANSPORT_REACHABLE_CONTRACT_UNCONFIRMED'
run wan_down
assert 'PROFILE_OBSERVATION: WAN_UNREADY'
! grep -q '^TARGET group=' "$work/out"

if run legacy; then echo 'FAIL: accepted legacy profile' >&2; exit 1; fi
if run invalid; then echo 'FAIL: accepted invalid config' >&2; exit 1; fi
printf 'PASS: grouped profile HTTPS contracts, RU/intl isolation, pinned path, DNS dependency and partial-failure semantics\n'
