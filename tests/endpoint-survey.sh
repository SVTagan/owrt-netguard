#!/bin/sh
# Deterministic offline tests of one-shot endpoint survey.
# No real HTTP/DNS, interface changes, or persistent files.
set -eu

script=${1:-./netguard-endpoint-survey}

# The production target runs under BusyBox ash. Catch non-portable case
# patterns and syntax errors before running the mocked endpoint scenarios.
if ! sh -n "$script"; then
    printf 'FAIL: endpoint survey has invalid POSIX shell syntax\n' >&2
    exit 1
fi

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/mock"

cat > "$work/mock/ubus" <<'MOCK'
#!/bin/sh
printf '%s\n' '{"up":true,"l3_device":"wan","pending":false}'
MOCK
cat > "$work/mock/jsonfilter" <<'MOCK'
#!/bin/sh
case "$*" in
    *'@.up'*) echo true ;;
    *'@.l3_device'*) echo wan ;;
esac
MOCK
cat > "$work/mock/ip" <<'MOCK'
#!/bin/sh
case "$*" in
    *'203.0.113.10'*) echo '203.0.113.10 dev awg0 src 10.0.0.1' ;;
    *) echo '1.1.1.1 via 192.0.2.1 dev wan src 192.0.2.2' ;;
esac
MOCK
cat > "$work/mock/curl" <<'MOCK'
#!/bin/sh
out=
url=
interface=
proto=
noproxy=
maxsize=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output) out=$2; shift 2 ;;
        --interface) interface=$2; shift 2 ;;
        --proto) proto=$2; shift 2 ;;
        --noproxy) noproxy=$2; shift 2 ;;
        --max-filesize) maxsize=$2; shift 2 ;;
        https://*) url=$1; shift ;;
        *) shift ;;
    esac
done
[ "$interface" = 'if!wan' ] && [ "$proto" = '=https' ] &&
    [ "$noproxy" = '*' ] && [ "$maxsize" = 131072 ] || exit 85
[ -n "$url" ] || exit 86
case "$url" in
    'https://ya.ru/') printf '200|77.88.8.88|0|0.234|1024' ;;
    'https://mail.ru/') printf '301|94.100.180.200|0|0.345|0' ;;
    'https://www.reg.ru/') printf '200|203.0.113.10|0|0.123|500' ;;
    'https://www.nic.ru/') printf '200|195.253.225.12|0|0.211|500' ;;
    'https://timeweb.com/') printf '200|185.178.46.33|0|1.101|131072'; exit 63 ;;
    'https://www.gstatic.com/generate_204') printf '204|142.250.20.3|0|0.150|0' ;;
    'https://captive.apple.com/hotspot-detect.html')
        printf '%s' 'Success' > "$out"
        printf '200|17.253.1.1|0|0.231|7' ;;
    'https://detectportal.firefox.com/success.txt')
        printf '%s' 'incorrect body' > "$out"
        printf '200|34.110.1.1|0|0.211|14' ;;
    *) printf '000|-|-|8.0|0'; exit 28 ;;
esac
MOCK
chmod +x "$work/mock"/*

run() {
    PATH="$work/mock:$PATH" sh "$script" "$@" >"$work/output"
}

run
grep -qx 'SUMMARY: targets=8 matched=5 redirects=1 body_limit=1 other_failures=1' "$work/output" || {
    cat "$work/output" >&2
    exit 1
}
grep -q 'TARGET group=ru_diverse name=reg' "$work/output"
grep -q 'result=MATCHED .*route_unmarked=OTHER_DEVICE' "$work/output"
grep -q 'TARGET group=international name=gstatic' "$work/output"
grep -q 'TARGET group=international name=mozilla' "$work/output"
grep -q 'result=CONTRACT_MISMATCH .*http=200' "$work/output"
grep -q 'TARGET group=ru_base name=mail' "$work/output"
grep -q 'result=REDIRECT .*http=301' "$work/output"
grep -q 'TARGET group=ru_diverse name=timeweb' "$work/output"
grep -q 'result=BODY_LIMIT .*curl_rc=63' "$work/output"

run --profile ru
grep -qx 'SUMMARY: targets=5 matched=3 redirects=1 body_limit=1 other_failures=0' "$work/output"
! grep -q 'group=international' "$work/output"

run --profile international
grep -qx 'SUMMARY: targets=3 matched=2 redirects=0 body_limit=0 other_failures=1' "$work/output"
! grep -q 'group=ru_base' "$work/output"

printf '%s\n' 'ru_base|only_ya|https://ya.ru/|2xx|-' > "$work/custom"
run --file "$work/custom"
grep -qx 'SUMMARY: targets=1 matched=1 redirects=0 body_limit=0 other_failures=0' "$work/output"

printf '%s\n' 'ru_base|bad|http://insecure.invalid/|any|-' > "$work/custom"
if PATH="$work/mock:$PATH" sh "$script" --file "$work/custom" >"$work/output" 2>&1; then
    echo 'FAIL: http URL accepted' >&2
    exit 1
fi

printf '%s\n' 'ru_base|bad|https://-evil.example/|any|-' > "$work/custom"
# A syntactically HTTPS URL is allowed by the survey; it is not a production
# endpoint validation or proof of real domain existence.
run --file "$work/custom"
grep -q 'result=ERROR' "$work/output"

if PATH="$work/mock:$PATH" sh "$script" --profile unknown >/dev/null 2>&1; then
    echo 'FAIL: bad profile accepted' >&2
    exit 1
fi
if OWRT_NETGUARD_WAN='wan;rm -rf /' PATH="$work/mock:$PATH" sh "$script" >/dev/null 2>&1; then
    echo 'FAIL: unsafe WAN identifier accepted' >&2
    exit 1
fi

printf 'PASS: endpoint survey RU/international contracts, redirects, body limits, routes and input validation\n'
