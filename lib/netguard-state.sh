# OWRT NetGuard: state transitions (POSIX shell, source-only).
# RAM-only prototype. No networking, writes, or service management.

ng_reset() {
    ng_phase=STARTUP
    ng_pending=
    ng_streak=0
    ng_recovery=0
    ng_incident=0
    ng_root=
    ng_escalate=0
    ng_last=
}

ng_observe_family() {
    case "$1" in
        HEALTHY_SAMPLED) ng_family=HEALTHY ;;
        WAN_LINK_DOWN|WAN_NO_L3) ng_family=WAN ;;
        LOCAL_DNS_UNAVAILABLE|EXTERNAL_DNS_UNCONFIRMED|DNS_PATH_UNCONFIRMED) ng_family=DNS ;;
        EXTERNAL_REACHABILITY_UNCONFIRMED) ng_family=CONNECTIVITY ;;
        PARTIAL_REACHABILITY) ng_family=DEGRADED ;;
        UNKNOWN_ROUTE) ng_family=UNKNOWN ;;
        *) return 2 ;;
    esac
}

ng_step() {
    [ "$#" -eq 1 ] || return 2
    ng_observe_family "$1" || return 2
    ng_last=$1

    if [ "$ng_family" = HEALTHY ]; then
        ng_escalate=0
        ng_streak=0
        ng_pending=
        if [ "$ng_phase" = OPEN ] || [ "$ng_phase" = RECOVERING ]; then
            ng_recovery=$((ng_recovery + 1))
            if [ "$ng_recovery" -ge 2 ]; then
                printf 'RESOLVED %s %s\n' "$ng_incident" "$ng_root"
                ng_phase=HEALTHY
                ng_root=
                ng_recovery=0
            else
                ng_phase=RECOVERING
            fi
        else
            ng_phase=HEALTHY
        fi
        return 0
    fi

    ng_recovery=0
    if [ "$ng_family" = UNKNOWN ]; then
        ng_streak=0
        ng_pending=
        ng_escalate=0
        case "$ng_phase" in
            OPEN|RECOVERING) ng_phase=OPEN ;;
            *) ng_phase=UNKNOWN ;;
        esac
        return 0
    fi

    if [ "$ng_phase" = OPEN ] || [ "$ng_phase" = RECOVERING ]; then
        ng_phase=OPEN
        # A confirmed WAN symptom can supersede DNS, but not after a
        # single possibly transient reading.
        if [ "$ng_family" = WAN ] && [ "$ng_root" != WAN ]; then
            ng_escalate=$((ng_escalate + 1))
            if [ "$ng_escalate" -ge 2 ]; then
                ng_root=WAN
                ng_escalate=0
                printf 'RECLASSIFIED %s WAN\n' "$ng_incident"
            fi
        else
            ng_escalate=0
        fi
        return 0
    fi

    if [ "$ng_pending" = "$ng_family" ]; then
        ng_streak=$((ng_streak + 1))
    else
        ng_pending=$ng_family
        ng_streak=1
    fi
    if [ "$ng_streak" -ge 3 ]; then
        ng_incident=$((ng_incident + 1))
        ng_root=$ng_family
        ng_phase=OPEN
        ng_pending=
        ng_streak=0
        printf 'OPEN %s %s\n' "$ng_incident" "$ng_root"
    else
        ng_phase=SUSPECT
    fi
}

ng_reset
