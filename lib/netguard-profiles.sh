#!/bin/sh
# OWRT NetGuard experimental endpoint profile loader (read-only).
# Source this file, then call ng_profiles_load [russia|international|custom].
# Never edits UCI or executes HTTP/DNS probes.

ng_profiles_error() {
    printf 'ERROR: profile configuration: %s\n' "$1" >&2
    return 2
}

ng_profiles_valid_ipv4() {
    case "$1" in ''|*[!0-9.]*|.*|*.|*..*) return 1 ;; esac
    ng_ipv4_ifs=$IFS
    IFS=.
    set -- $1
    IFS=$ng_ipv4_ifs
    [ "$#" -eq 4 ] || return 1
    for ng_octet in "$@"; do
        case "$ng_octet" in ''|*[!0-9]*) return 1 ;; esac
        [ "${#ng_octet}" -le 3 ] &&
            [ "$ng_octet" -ge 0 ] 2>/dev/null &&
            [ "$ng_octet" -le 255 ] 2>/dev/null || return 1
    done
    return 0
}

ng_profiles_check_target() {
    ng_entry=$1
    # Seven fields / exactly six separators. Do not silently swallow extras.
    ng_left=$ng_entry
    ng_bars=0
    while [ "${ng_left#*|}" != "$ng_left" ]; do
        ng_left=${ng_left#*|}
        ng_bars=$((ng_bars + 1))
    done
    [ "$ng_bars" -eq 6 ] || { ng_profiles_error 'HTTPS target must have exactly 7 fields'; return 2; }
    ng_saved_ifs=$IFS
    IFS='|'
    read -r ng_group ng_name ng_host ng_address ng_path ng_http ng_body <<NG_TARGET
$ng_entry
NG_TARGET
    IFS=$ng_saved_ifs

    case "$ng_group" in
        ru_base|ru_diverse|international) ;;
        *) ng_profiles_error 'invalid HTTPS target group'; return 2 ;;
    esac
    case "$ng_name" in
        ''|*[!a-zA-Z0-9_-]*) ng_profiles_error 'invalid HTTPS target name'; return 2 ;;
    esac
    [ "${#ng_name}" -le 32 ] || { ng_profiles_error 'HTTPS target name too long'; return 2; }
    case " $NG_PROFILE_NAMES " in
        *" $ng_name "*) ng_profiles_error "duplicate HTTPS target name: $ng_name"; return 2 ;;
    esac
    case "$ng_host" in
        ''|*[!a-zA-Z0-9.-]*|.*|*..*|*.|-*|*-|*.-*|*-.*)
            ng_profiles_error "invalid TLS hostname for $ng_name"; return 2 ;;
    esac
    [ "${#ng_host}" -le 253 ] || { ng_profiles_error "TLS hostname too long: $ng_name"; return 2; }
    case "$ng_host" in *.*) ;; *) ng_profiles_error "TLS hostname must be FQDN: $ng_name"; return 2 ;; esac
    if [ "$ng_address" = auto ]; then
        ng_dns_mode=SYSTEM
    elif ng_profiles_valid_ipv4 "$ng_address"; then
        ng_dns_mode=PINNED
    else
        ng_profiles_error "invalid IPv4/auto value: $ng_name"
        return 2
    fi
    case "$ng_path" in /*) ;; *) ng_profiles_error "invalid HTTPS path: $ng_name"; return 2 ;; esac
    # Strictly whitelist URI characters: no spaces, shell metacharacters,
    # fragment (#), backslashes, vertical bar or control characters.
    if ! printf '%s\n' "$ng_path" | LC_ALL=C grep -Eq '^/[A-Za-z0-9._~:/?&=%+@,-]*$'; then
        ng_profiles_error "unsafe HTTPS path: $ng_name"
        return 2
    fi
    [ "${#ng_path}" -le 200 ] || { ng_profiles_error "HTTPS path too long: $ng_name"; return 2; }
    case "$ng_http" in
        2xx|[1-5][0-9][0-9]) ;;
        *) ng_profiles_error "invalid HTTP expectation: $ng_name"; return 2 ;;
    esac
    case "$ng_body" in
        -) ;;
        ''|*[!a-zA-Z0-9_-]*) ng_profiles_error "invalid body token: $ng_name"; return 2 ;;
    esac
    [ "${#ng_body}" -le 80 ] || { ng_profiles_error "body token too long: $ng_name"; return 2; }
    NG_PROFILE_COUNT=$((NG_PROFILE_COUNT + 1))
    [ "$NG_PROFILE_COUNT" -le 12 ] || { ng_profiles_error 'maximum 12 HTTPS targets'; return 2; }
    NG_PROFILE_NAMES="$NG_PROFILE_NAMES $ng_name"
    case "$ng_group" in
        ru_base) NG_PROFILE_RU_BASE=$((NG_PROFILE_RU_BASE + 1)) ;;
        ru_diverse) NG_PROFILE_RU_DIVERSE=$((NG_PROFILE_RU_DIVERSE + 1)) ;;
        international) NG_PROFILE_INTL=$((NG_PROFILE_INTL + 1)) ;;
    esac
    if [ -n "$NG_PROFILE_TARGETS" ]; then
        NG_PROFILE_TARGETS="$NG_PROFILE_TARGETS
$ng_entry"
    else
        NG_PROFILE_TARGETS=$ng_entry
    fi
    return 0
}

ng_profiles_load() {
    NG_PROFILE_SELECTED=
    NG_PROFILE_SOURCE=
    NG_PROFILE_TARGETS=
    NG_PROFILE_NAMES=
    NG_PROFILE_COUNT=0
    NG_PROFILE_RU_BASE=0
    NG_PROFILE_RU_DIVERSE=0
    NG_PROFILE_INTL=0
    ng_requested=${1:-}
    ng_cfg_dir=${OWRT_NETGUARD_CONFIG_DIR:-/etc/config}
    ng_uci_profile=
    ng_uci_targets=

    # Do not require UCI if the user only wants to inspect built-in drafts.
    if [ -r "$ng_cfg_dir/netguard" ]; then
        command -v uci >/dev/null 2>&1 || { ng_profiles_error 'UCI is unavailable'; return 2; }
        uci -q -c "$ng_cfg_dir" show netguard >/dev/null 2>&1 || {
            ng_profiles_error 'UCI config cannot be parsed'
            return 2
        }
        ng_uci_profile=$(uci -q -c "$ng_cfg_dir" get netguard.main.profile 2>/dev/null) || ng_uci_profile=
        ng_uci_targets=$(uci -q -c "$ng_cfg_dir" get netguard.main.https_target 2>/dev/null) || ng_uci_targets=
    fi
    if [ -n "$ng_requested" ]; then
        NG_PROFILE_SELECTED=$ng_requested
        NG_PROFILE_SOURCE=cli
    elif [ -n "$ng_uci_profile" ]; then
        NG_PROFILE_SELECTED=$ng_uci_profile
        NG_PROFILE_SOURCE=uci
    else
        # Backwards-compatibility: legacy check is the only active engine.
        NG_PROFILE_SELECTED=legacy
        NG_PROFILE_SOURCE=legacy
    fi
    case "$NG_PROFILE_SELECTED" in
        legacy)
            [ -z "$ng_uci_targets" ] || { ng_profiles_error 'https_target requires an explicitly selected profile'; return 2; }
            return 0 ;;
        russia|international|custom) ;;
        *) ng_profiles_error 'unknown profile (russia, international, custom)'; return 2 ;;
    esac

    if [ -n "$ng_uci_targets" ]; then
        NG_PROFILE_SOURCE="$NG_PROFILE_SOURCE+uci-targets"
        ng_source=$ng_uci_targets
    else
        case "$NG_PROFILE_SELECTED" in
            russia)
                ng_source='ru_diverse|selectel|selectel.ru|auto|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|auto|/robots.txt|200|User-agent' ;;
            international)
                ng_source='international|gstatic|www.gstatic.com|auto|/generate_204|204|-
international|apple|captive.apple.com|auto|/hotspot-detect.html|200|Success
international|mozilla|detectportal.firefox.com|auto|/success.txt|200|success' ;;
            custom)
                ng_profiles_error 'custom profile requires explicit list https_target'; return 2 ;;
        esac
        NG_PROFILE_SOURCE="$NG_PROFILE_SOURCE+builtin-candidates"
    fi

    # UCI 'get' joins list items with whitespace; seven-field entries
    # expressly forbid whitespace. Temporarily disable pathname expansion
    # without changing the caller's previous noglob setting.
    ng_restore_glob=0
    case $- in *f*) ;; *) set -f; ng_restore_glob=1 ;; esac
    for ng_item in $ng_source; do
        if ! ng_profiles_check_target "$ng_item"; then
            [ "$ng_restore_glob" -eq 0 ] || set +f
            return 2
        fi
    done
    [ "$ng_restore_glob" -eq 0 ] || set +f
    [ "$NG_PROFILE_COUNT" -gt 0 ] || { ng_profiles_error 'no HTTPS targets'; return 2; }
    case "$NG_PROFILE_SELECTED" in
        russia)
            [ "$NG_PROFILE_RU_DIVERSE" -gt 0 ] || {
                ng_profiles_error 'russia profile requires ru_diverse target(s)'; return 2;
            } ;;
        international)
            [ "$NG_PROFILE_INTL" -gt 0 ] || {
                ng_profiles_error 'international profile requires international target(s)'; return 2;
            } ;;
    esac
    return 0
}
