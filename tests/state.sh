#!/bin/sh
# Deterministic incident-state tests. No network, flash, or OpenWrt required.
set -eu

library=${1:-./lib/netguard-state.sh}
. "$library"

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM

steps=0
feed() {
    observation=$1
    expected_event=$2
    expected_phase=$3
    expected_root=$4

    # Redirect rather than command substitution: source-library variables must
    # be updated in this shell, not a subshell.
    ng_step "$observation" > "$work/event"
    event=$(cat "$work/event")
    if [ "$event" != "$expected_event" ] || [ "$ng_phase" != "$expected_phase" ]; then
        printf 'FAIL obs=%s: event="%s" phase=%s (want "%s" %s)\n' \
            "$observation" "$event" "$ng_phase" "$expected_event" "$expected_phase" >&2
        exit 1
    fi
    if [ "$expected_root" = NONE ]; then
        [ -z "$ng_root" ] || {
            printf 'FAIL root=%s; expected empty\n' "$ng_root" >&2
            exit 1
        }
    else
        [ "$ng_root" = "$expected_root" ] || {
            printf 'FAIL root=%s; expected %s\n' "$ng_root" "$expected_root" >&2
            exit 1
        }
    fi
    steps=$((steps + 1))
}

# Cold start and transient outage: no incident until sustained failure.
ng_reset
feed HEALTHY_SAMPLED '' HEALTHY NONE
feed WAN_NO_L3 '' SUSPECT NONE
feed HEALTHY_SAMPLED '' HEALTHY NONE
[ "$ng_incident" -eq 0 ]

# Sustained WAN problem and downstream DNS symptoms form one incident.
feed WAN_LINK_DOWN '' SUSPECT NONE
feed WAN_NO_L3 '' SUSPECT NONE
feed WAN_LINK_DOWN 'OPEN 1 WAN' OPEN WAN
feed LOCAL_DNS_UNAVAILABLE '' OPEN WAN
feed DNS_PATH_UNCONFIRMED '' OPEN WAN
[ "$ng_incident" -eq 1 ]

# A single successful sample does not resolve an open incident.
feed HEALTHY_SAMPLED '' RECOVERING WAN
feed WAN_NO_L3 '' OPEN WAN
feed HEALTHY_SAMPLED '' RECOVERING WAN
feed HEALTHY_SAMPLED 'RESOLVED 1 WAN' HEALTHY NONE

# New outage after confirmed recovery must be a separate incident.
feed WAN_NO_L3 '' SUSPECT NONE
feed WAN_NO_L3 '' SUSPECT NONE
feed WAN_NO_L3 'OPEN 2 WAN' OPEN WAN
feed HEALTHY_SAMPLED '' RECOVERING WAN
feed HEALTHY_SAMPLED 'RESOLVED 2 WAN' HEALTHY NONE

# DNS incident: later WAN evidence takes priority only if repeated.
ng_reset
feed LOCAL_DNS_UNAVAILABLE '' SUSPECT NONE
feed LOCAL_DNS_UNAVAILABLE '' SUSPECT NONE
feed LOCAL_DNS_UNAVAILABLE 'OPEN 1 DNS' OPEN DNS
feed WAN_LINK_DOWN '' OPEN DNS
feed EXTERNAL_DNS_UNCONFIRMED '' OPEN DNS
feed WAN_LINK_DOWN '' OPEN DNS
feed WAN_NO_L3 'RECLASSIFIED 1 WAN' OPEN WAN
feed DNS_PATH_UNCONFIRMED '' OPEN WAN

# UNKNOWN must never be treated as confirmed recovery (or proof of ISP fault).
ng_reset
feed HEALTHY_SAMPLED '' HEALTHY NONE
feed UNKNOWN_ROUTE '' UNKNOWN NONE
feed UNKNOWN_ROUTE '' UNKNOWN NONE
feed WAN_LINK_DOWN '' SUSPECT NONE
feed UNKNOWN_ROUTE '' UNKNOWN NONE
feed WAN_NO_L3 '' SUSPECT NONE
feed WAN_NO_L3 '' SUSPECT NONE
feed WAN_NO_L3 'OPEN 1 WAN' OPEN WAN
feed HEALTHY_SAMPLED '' RECOVERING WAN
feed UNKNOWN_ROUTE '' OPEN WAN
feed HEALTHY_SAMPLED '' RECOVERING WAN
feed HEALTHY_SAMPLED 'RESOLVED 1 WAN' HEALTHY NONE

# Degraded connectivity must not be mislabeled as a confirmed WAN outage.
ng_reset
feed PARTIAL_REACHABILITY '' SUSPECT NONE
feed PARTIAL_REACHABILITY '' SUSPECT NONE
feed PARTIAL_REACHABILITY 'OPEN 1 DEGRADED' OPEN DEGRADED
feed DNS_PATH_UNCONFIRMED '' OPEN DEGRADED
feed HEALTHY_SAMPLED '' RECOVERING DEGRADED
feed HEALTHY_SAMPLED 'RESOLVED 1 DEGRADED' HEALTHY NONE

# An internal check failure must remain UNKNOWN and must not open a WAN incident.
ng_reset
feed PROBE_ERROR '' UNKNOWN NONE
feed PROBE_ERROR '' UNKNOWN NONE
feed HEALTHY_SAMPLED '' HEALTHY NONE

# netifd setup and the bounded service grace are not failures.
ng_reset
feed STARTUP_WAIT '' STARTUP NONE
feed WAN_INITIALIZING '' STARTUP NONE
feed HEALTHY_SAMPLED '' HEALTHY NONE

# After the worker grace expires, a WAN without L3 is diagnosed normally.
feed WAN_NO_L3 '' SUSPECT NONE
feed WAN_NO_L3 '' SUSPECT NONE
feed WAN_NO_L3 'OPEN 1 WAN' OPEN WAN
# A later interface reconfiguration does not fabricate a recovery event.
feed WAN_INITIALIZING '' OPEN WAN
feed HEALTHY_SAMPLED '' RECOVERING WAN
feed HEALTHY_SAMPLED 'RESOLVED 1 WAN' HEALTHY NONE

# Invalid status must be rejected without changing incident state.
phase_before=$ng_phase
if ng_step INVALID_RESULT > "$work/event"; then
    echo 'FAIL invalid observation unexpectedly accepted' >&2
    exit 1
else
    rc=$?
    [ "$rc" -eq 2 ] || {
        printf 'FAIL invalid observation returned %s instead of 2\n' "$rc" >&2
        exit 1
    }
fi
[ "$ng_phase" = "$phase_before" ]

printf 'PASS: %s state transitions, scenario coverage for incidents, recovery and UNKNOWN\n' "$steps"
