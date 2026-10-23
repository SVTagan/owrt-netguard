#!/bin/sh
# Offline tests for netguard-dns-probe; no real DNS, WAN, or UCI changes.
set -eu
script=${1:-./netguard-dns-probe}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/mocks"
cat > "$work/mocks/ubus" <<'MOCK'
#!/bin/sh
printf '%s\n' '{"up":true,"l3_device":"wan"}'
MOCK
cat > "$work/mocks/jsonfilter" <<'MOCK'
#!/bin/sh
case "$*" in *'@.up'*) case "${DNS_TEST_MODE:-}" in wan_down) echo false;; *) echo true;; esac;;
*'@.l3_device'*) echo wan;; esac
MOCK
cat > "$work/mocks/ip" <<'MOCK'
#!/bin/sh
case "${DNS_TEST_MODE:-}" in mismatch) echo '203.0.113.1 dev awg0';; *) echo '203.0.113.1 dev wan';; esac
MOCK
cat > "$work/mocks/nslookup" <<'MOCK'
#!/bin/sh
for last; do :; done
server=$last
case "${DNS_TEST_MODE:-}:$server" in
    local_down:127.0.0.1|all_fail:*|intl_blocked:1.1.1.1|intl_blocked:8.8.8.8|ru_blocked:77.88.8.8|ru_blocked:193.58.251.251)
        printf '%s\n' 'Server: server' 'Address: 203.0.113.53:53'
        exit 1;;
    spoofed_header:193.58.251.251)
        printf '%s\n' 'Server: dns' 'Address: 192.0.2.53' 'Name: example.com' 'Address: ::1'
        exit 0;;
esac
printf '%s\n' 'Server: dns' 'Address: 192.0.2.53:53' 'Non-authoritative answer:' 'Name: example.com' 'Address: 93.184.215.14'
MOCK
chmod +x "$work/mocks"/*
run() {
 DNS_TEST_MODE=${1:-} PATH="$work/mocks:$PATH" sh "$script" --profile "${2:-russia}" > "$work/out" 2>"$work/err"
}
assert() {
 grep -Fq -- "$1" "$work/out" || { printf 'FAIL: expected %s\n' "$1" >&2; cat "$work/out" >&2; exit 1; }
}
run normal
assert 'DNS_GROUP local targets=1 answers=1'
assert 'DNS_GROUP ru targets=2 answers=2'
assert 'DNS_GROUP international targets=0 answers=0'
assert 'DNS_OBSERVATION: LOCAL_AND_EXTERNAL_DNS_ANSWER_SAMPLED'
run local_down
assert 'DNS_GROUP local targets=1 answers=0'
assert 'DNS_GROUP ru targets=2 answers=2'
assert 'DNS_OBSERVATION: EXTERNAL_DNS_ANSWER_LOCAL_UNCONFIRMED'
run ru_blocked
assert 'DNS_GROUP ru targets=2 answers=0'
assert 'DNS_OBSERVATION: LOCAL_DNS_ANSWER_SAMPLED'
run all_fail
assert 'DNS_GROUP ru targets=2 answers=0'
assert 'DNS_OBSERVATION: DNS_ANSWERS_UNCONFIRMED'
run spoofed_header
assert 'DNS_GROUP ru targets=2 answers=1'
assert 'DNS_TARGET group=ru name=skydns resolver=193.58.251.251 result=UNCONFIRMED'
run mismatch
assert 'DNS_SUMMARY failed=0 skipped=2'
assert 'result=SKIPPED_ROUTE route_unmarked=OTHER_DEVICE'
run wan_down
assert 'DNS_SUMMARY failed=0 skipped=2'
assert 'DNS_OBSERVATION: LOCAL_DNS_ANSWER_SAMPLED'
run intl_blocked international
assert 'DNS_GROUP international targets=2 answers=0'
assert 'DNS_GROUP local targets=1 answers=1'
run normal international
assert 'DNS_GROUP international targets=2 answers=2'

cat > "$work/custom" <<'DATA'
local|local_user|127.0.0.1|example.com
ru|custom_ru|192.0.2.11|iana.org
DATA
DNS_TEST_MODE=normal PATH="$work/mocks:$PATH" sh "$script" --profile custom --file "$work/custom" >"$work/out"
assert 'DNS_GROUP ru targets=1 answers=1'

cat > "$work/custom" <<'DATA'
local|notloopback|8.8.8.8|example.com
DATA
if DNS_TEST_MODE=normal PATH="$work/mocks:$PATH" sh "$script" --profile custom --file "$work/custom" >"$work/out" 2>&1; then
 echo 'FAIL: accepted unsafe local target' >&2; exit 1
fi
cat > "$work/custom" <<'DATA'
ru|injection|1.1.1.1|example.com;reboot
DATA
if DNS_TEST_MODE=normal PATH="$work/mocks:$PATH" sh "$script" --profile custom --file "$work/custom" >"$work/out" 2>&1; then
 echo 'FAIL: accepted unsafe domain' >&2; exit 1
fi
cat > "$work/custom" <<'DATA'
ru|one|1.1.1.1|example.com
ru|one|9.9.9.9|example.com
DATA
if DNS_TEST_MODE=normal PATH="$work/mocks:$PATH" sh "$script" --profile custom --file "$work/custom" >"$work/out" 2>&1; then
 echo 'FAIL: accepted duplicate label' >&2; exit 1
fi
printf '%s\n' 'PASS: isolated DNS sample groups, local failures, filtered resolvers, route skips, answer parsing and config validation'
