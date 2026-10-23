#!/bin/sh
# Offline tests for opt-in WAN-only check; never touch real network.
set -eu
script=${1:-./netguard-wan-check}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin"
cat > "$work/profiles.sh" <<'MOCK'
ng_profiles_load() {
    NG_PROFILE_SELECTED=${OWRT_NETGUARD_PROFILE:-russia}
    [ "${NG_TEST_SCENARIO:-}" != legacy ] || NG_PROFILE_SELECTED=legacy
    NG_PROFILE_TARGETS='ru_diverse|selectel|selectel.ru|94.26.255.104|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|185.65.148.89|/robots.txt|200|User-agent'
    case "${NG_TEST_SCENARIO:-}" in
        auto) NG_PROFILE_TARGETS='ru_diverse|selectel|selectel.ru|auto|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|185.65.148.89|/robots.txt|200|User-agent' ;;
        duplicate) NG_PROFILE_TARGETS='ru_diverse|selectel|selectel.ru|94.26.255.104|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|94.26.255.104|/robots.txt|200|User-agent' ;;
        singleton) NG_PROFILE_TARGETS='ru_diverse|selectel|selectel.ru|94.26.255.104|/robots.txt|200|User-agent' ;;
        ru_base_only) NG_PROFILE_TARGETS='ru_base|allow_1|allow-one.ru|192.0.2.11|/|200|-
ru_base|allow_2|allow-two.ru|192.0.2.12|/|200|-
ru_diverse|selectel|selectel.ru|94.26.255.104|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|185.65.148.89|/robots.txt|200|User-agent' ;;
        international)
            NG_PROFILE_SELECTED=international
            NG_PROFILE_TARGETS='international|apple|captive.apple.com|17.1.1.1|/x|200|Success
international|mozilla|detectportal.firefox.com|63.1.1.1|/x|200|success' ;;
        custom)
            NG_PROFILE_SELECTED=custom
            NG_PROFILE_TARGETS='ru_diverse|one|selectel.ru|94.26.255.104|/robots.txt|200|User-agent
international|two|captive.apple.com|17.1.1.1|/x|200|Success' ;;
    esac
    return 0
}
MOCK
cat > "$work/bin/ubus" <<'MOCK'
#!/bin/sh
printf '%s\n' '{"up":true,"pending":false,"device":"wan","l3_device":"wan"}'
MOCK
cat > "$work/bin/jsonfilter" <<'MOCK'
#!/bin/sh
case "$*" in
    *'@.up'*) case "${NG_TEST_SCENARIO:-}" in wan_down|wan_pending) echo false;; *) echo true;; esac ;;
    *'@.pending'*) case "${NG_TEST_SCENARIO:-}" in wan_pending) echo true;; *) echo false;; esac ;;
    *'@.l3_device'*) case "${NG_TEST_SCENARIO:-}" in wan_down|wan_pending) ;; *) echo wan;; esac ;;
    *'@.device'*) echo wan ;;
esac
MOCK
cat > "$work/probe.sh" <<'MOCK'
#!/bin/sh
case "${NG_TEST_SCENARIO:-}" in
    probe_error) echo 'ERROR: sampler unavailable'; exit 2 ;;
    missing_observation) echo 'TARGET group=ru_diverse name=selectel dns=PINNED result=MATCHED curl_rc=0 http=200'; exit 0 ;;
    child_wan_down) echo 'PROFILE_OBSERVATION: WAN_UNREADY'; exit 0 ;;
esac
emit() {
    printf 'TARGET group=%s name=%s dns=PINNED result=%s curl_rc=%s http=%s tls_verify=0 remote_ip=94.26.255.104 route_unmarked=MATCHES_WAN\n' "$1" "$2" "$3" "$4" "$5"
}
case "${NG_TEST_SCENARIO:-}" in
    one) emit ru_diverse selectel MATCHED 0 200; emit ru_diverse timeweb TIMEOUT 28 000 ;;
    ru_base_only)
        emit ru_base allow_1 MATCHED 0 200; emit ru_base allow_2 MATCHED 0 200
        emit ru_diverse selectel TIMEOUT 28 000; emit ru_diverse timeweb TIMEOUT 28 000 ;;
    all_fail) emit ru_diverse selectel TIMEOUT 28 000; emit ru_diverse timeweb TLS_FAILED 60 000 ;;
    route_uncertain) emit ru_diverse selectel SKIPPED_ROUTE 0 000; emit ru_diverse timeweb TIMEOUT 28 000 ;;
    bind_failure) emit ru_diverse selectel CONNECT_FAILED 45 000; emit ru_diverse timeweb TIMEOUT 28 000 ;;
    redirect) emit ru_diverse selectel REDIRECT 0 302; emit ru_diverse timeweb CONTRACT_MISMATCH 0 200 ;;
    international) emit international apple MATCHED 0 200; emit international mozilla MATCHED 0 200 ;;
    custom) emit ru_diverse one MATCHED 0 200; emit international two MATCHED 0 200 ;;
    *) emit ru_diverse selectel MATCHED 0 200; emit ru_diverse timeweb MATCHED 0 200 ;;
esac
echo 'PROFILE_OBSERVATION: RU_REACHABLE_SAMPLED'
MOCK
chmod +x "$work/bin/"* "$work/probe.sh"

run() {
    name=$1 expected=$2 wanted_rc=$3
    set +e
    output=$(PATH="$work/bin:$PATH" NG_TEST_SCENARIO="$name" \
        NETGUARD_PROFILES_LIB="$work/profiles.sh" NETGUARD_PROFILE_PROBE="$work/probe.sh" \
        sh "$script" check 2>&1)
    rc=$?
    set -e
    [ "$rc" -eq "$wanted_rc" ] || {
        printf 'FAIL %s: exit %s wanted %s\n%s\n' "$name" "$rc" "$wanted_rc" "$output" >&2
        exit 1
    }
    case "$expected" in
        ERROR) printf '%s\n' "$output" | grep -Fq 'ERROR:' ;;
        *) printf '%s\n' "$output" | grep -Fq "RESULT: $expected" ;;
    esac || {
        printf 'FAIL %s: unexpected output\n%s\n' "$name" "$output" >&2
        exit 1
    }
    printf 'PASS %s -> %s\n' "$name" "$expected"
}
run healthy HEALTHY_SAMPLED 0
run one PARTIAL_REACHABILITY 1
run ru_base_only PARTIAL_REACHABILITY 1
run all_fail EXTERNAL_REACHABILITY_UNCONFIRMED 1
run route_uncertain UNKNOWN_ROUTE 1
run bind_failure UNKNOWN_ROUTE 1
run redirect PARTIAL_REACHABILITY 1
run international HEALTHY_SAMPLED 0
run custom HEALTHY_SAMPLED 0
run wan_down WAN_NO_L3 1
run wan_pending WAN_INITIALIZING 1
run child_wan_down WAN_NO_L3 1
run missing_observation ERROR 2
run probe_error ERROR 2
run auto ERROR 2
run duplicate ERROR 2
run singleton ERROR 2
run legacy ERROR 2
printf '%s\n' 'PASS: WAN-only pinned-IP quorum, allowlist isolation, fail-closed configuration, conservative routing and worker result contract'
