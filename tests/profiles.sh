#!/bin/sh
# Completely offline tests: no OpenWrt network or persistent configuration.
set -eu
cli=${1:-./netguard-profiles}
lib=${2:-./lib/netguard-profiles.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/mocks" "$work/config" "$work/empty"
printf 'config netguard main\n' > "$work/config/netguard"

cat > "$work/mocks/uci" <<'MOCK'
#!/bin/sh
for last do :; done
case "$*" in
    *'show netguard')
        [ "${NG_TEST_MODE:-}" != malformed_uci ]; exit $? ;;
    *'get netguard.main.profile')
        case "${NG_TEST_MODE:-}" in
            russia_uci|custom_uci|bad_*) echo "${NG_TEST_PROFILE:-custom}" ;;
            unknown_profile) echo unknown ;;
            *) exit 1 ;;
        esac ;;
    *'get netguard.main.https_target')
        case "${NG_TEST_MODE:-}" in
            custom_uci)
                printf '%s\n' 'ru_diverse|siteA|example.com|auto|/robots.txt?a=1&b=2|200|User-agent international|siteB|host.example|192.0.2.15|/health|204|-'
                ;;
            russia_uci)
                printf '%s\n' 'ru_diverse|custom_ru|host.example|198.51.100.2|/check|200|Good'
                ;;
            bad_*) printf '%s\n' "$NG_TEST_TARGET" ;;
            *) exit 1 ;;
        esac ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$work/mocks/uci"

call() {
    NG_TEST_MODE="${NG_TEST_MODE:-}" NG_TEST_TARGET="${NG_TEST_TARGET:-}" NG_TEST_PROFILE="${NG_TEST_PROFILE:-}" \
    PATH="$work/mocks:$PATH" NETGUARD_PROFILES_LIB="$lib" \
    OWRT_NETGUARD_CONFIG_DIR="$NG_CONFIG_DIR" \
    sh "$cli" "$@" > "$work/output" 2> "$work/error"
}

NG_CONFIG_DIR=$work/empty
NG_TEST_MODE=
call show
grep -q '^PROFILE selected=legacy source=legacy targets=0$' "$work/output"
grep -q '^LEGACY_UNCHANGED:' "$work/output"

call show --profile russia
grep -q 'PROFILE selected=russia source=cli+builtin-candidates targets=2' "$work/output"
grep -q '^GROUP_COUNTS ru_base=0 ru_diverse=2 international=0$' "$work/output"
grep -q 'LIMITED_TARGET_DIVERSITY' "$work/output"
grep -q 'TARGET ru_diverse|selectel|selectel.ru|auto|/robots.txt|200|User-agent dns=SYSTEM' "$work/output"
call validate --profile russia
if grep -q '^TARGET ' "$work/output"; then echo 'FAIL: validate printed target rows' >&2; exit 1; fi

call show --profile international
grep -q 'PROFILE selected=international source=cli+builtin-candidates targets=3' "$work/output"
grep -q '^GROUP_COUNTS ru_base=0 ru_diverse=0 international=3$' "$work/output"
call validate --profile international

NG_CONFIG_DIR=$work/config
NG_TEST_MODE=custom_uci
NG_TEST_PROFILE=custom
call show
grep -q 'PROFILE selected=custom source=uci+uci-targets targets=2' "$work/output"
grep -Fq '/robots.txt?a=1&b=2|200|User-agent dns=SYSTEM' "$work/output"
grep -Fq '192.0.2.15|/health|204|- dns=PINNED' "$work/output"
NG_TEST_MODE=russia_uci
NG_TEST_PROFILE=russia
call show
grep -q 'PROFILE selected=russia source=uci+uci-targets targets=1' "$work/output"
grep -q 'custom_ru|host.example|198.51.100.2|/check|200|Good dns=PINNED' "$work/output"

# Bad UCI syntax is fatal, never silently use built-in targets.
NG_TEST_MODE=malformed_uci
if call show --profile russia; then echo 'FAIL: accepted malformed UCI' >&2; exit 1; fi

afail() {
    NG_TEST_MODE=bad_case
    NG_TEST_PROFILE=${2:-custom}
    NG_TEST_TARGET=$1
    if call validate; then
        printf 'FAIL: accepted invalid profile target: %s\n' "$NG_TEST_TARGET" >&2
        exit 1
    fi
    grep -q '^ERROR: profile configuration:' "$work/error"
}

afail 'bad|name|example.com|auto|/robots.txt|200|-'
afail 'ru_diverse|bad name|example.com|auto|/robots.txt|200|-'
afail 'ru_diverse|x|example..com|auto|/robots.txt|200|-'
afail 'ru_diverse|x|example.com|256.1.1.1|/robots.txt|200|-'
afail 'ru_diverse|x|example.com|192.0.2.1|robots.txt|200|-'
afail 'ru_diverse|x|example.com|auto|/robots.txt;touch|200|-'
afail 'ru_diverse|x|example.com|auto|/robots.txt|999|-'
afail 'ru_diverse|x|example.com|auto|/robots.txt|200|No Spaces'
afail 'ru_diverse|x|example.com|auto|/robots.txt|200|-|extra'
afail 'ru_diverse|x|example.com|auto|/robots.txt|200'
afail 'ru_diverse|x|example.com|auto|/robots.txt|200|- ru_diverse|x|example.com|auto|/robots.txt|200|-'
afail 'international|x|example.com|auto|/health|200|-' russia
# Group requirements are checked for configured profiles.
NG_TEST_MODE=bad_case
NG_TEST_PROFILE=international
NG_TEST_TARGET='ru_diverse|x|example.com|auto|/ok|200|-'
if call show; then echo 'FAIL: international accepted only RU targets' >&2; exit 1; fi
NG_TEST_MODE=unknown_profile
if call validate; then echo 'FAIL: accepted unknown profile' >&2; exit 1; fi

NG_CONFIG_DIR=$work/empty
NG_TEST_MODE=
if call show --profile custom; then echo 'FAIL: accepted custom profile with no targets' >&2; exit 1; fi
if call show --profile unknown; then echo 'FAIL: accepted invalid explicit profile' >&2; exit 1; fi
if call show --profile russia --extra yes; then echo 'FAIL: extra arguments accepted' >&2; exit 1; fi

printf 'PASS: profiles builtins, explicit opt-in, UCI overrides, pinned/auto DNS, and invalid configurations\n'
