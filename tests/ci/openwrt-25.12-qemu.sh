#!/usr/bin/env bash
# Manual GitHub Actions smoke test against an official OpenWrt 25.12.5 x86_64 VM.
# Runs on a disposable CI runner; it never touches a user's router.
set -Eeuo pipefail

readonly RELEASE=25.12.5
readonly IMAGE="openwrt-${RELEASE}-x86-64-generic-ext4-combined.img.gz"
readonly IMAGE_SHA256=23e2538e8ab0eb52dfed1c65d608ecdb71ffd432dd54885da138ae67cd9e4461
readonly IMAGE_URL="https://downloads.openwrt.org/releases/${RELEASE}/targets/x86/64/${IMAGE}"
readonly WORK="$(mktemp -d)"
readonly SSH_PORT=2222

cleanup() {
    if [[ -f "$WORK/qemu.pid" ]]; then
        kill "$(cat "$WORK/qemu.pid")" 2>/dev/null || true
    fi
    echo "== Last guest serial output =="
    if [[ -f "$WORK/serial.log" ]]; then
        tail -n 100 "$WORK/serial.log" || true
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

echo "== Download verified official OpenWrt image =="
curl --fail --location --silent --show-error --retry 2 --connect-timeout 15 \
    --max-time 120 "$IMAGE_URL" -o "$WORK/$IMAGE"
printf '%s  %s\n' "$IMAGE_SHA256" "$WORK/$IMAGE" | sha256sum --check
gzip -d "$WORK/$IMAGE"

echo "== Boot OpenWrt ${RELEASE} under QEMU =="
qemu-system-x86_64 \
    -M q35 -accel tcg -m 512 -smp 1 \
    -drive "file=$WORK/${IMAGE%.gz},format=raw,if=virtio" \
    -netdev "user,id=lan,net=192.168.1.0/24,hostfwd=tcp:127.0.0.1:${SSH_PORT}-192.168.1.1:22" \
    -device virtio-net-pci,netdev=lan \
    -netdev "user,id=wan,net=10.1.1.0/24" \
    -device virtio-net-pci,netdev=wan \
    -display none -serial "file:$WORK/serial.log" -monitor none \
    -pidfile "$WORK/qemu.pid" -daemonize

ssh_guest() {
    # Disposable guest uses the OpenWrt default blank root password.
    # This forwarded port binds only to the CI runner's loopback address.
    sshpass -p '' ssh -T -n \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 \
        -o ConnectionAttempts=1 \
        -o PreferredAuthentications=none,password,keyboard-interactive \
        -p "$SSH_PORT" root@127.0.0.1 "$@"
}
ssh_input() {
    sshpass -p '' ssh -T \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=3 \
        -o PreferredAuthentications=none,password,keyboard-interactive \
        -p "$SSH_PORT" root@127.0.0.1 "$@"
}

echo "== Wait for OpenWrt SSH =="
ready=0
for ((i=0; i<60; i++)); do
    if ssh_guest 'test -r /etc/openwrt_release && command -v ubus >/dev/null' >/dev/null 2>&1; then
        ready=1
        break
    fi
    sleep 3
done
if [[ "$ready" != 1 ]]; then
    echo "ERROR: QEMU guest did not become reachable via SSH" >&2
    exit 1
fi

echo "== Verify OS and built-in utilities =="
ssh_guest 'cat /etc/openwrt_release; echo; apk --version; echo; ubus list network.interface.*; echo; nslookup -h 2>&1 | head -n 12 || true'
ssh_guest "grep -q \"DISTRIB_RELEASE='${RELEASE}'\" /etc/openwrt_release"

echo "== Install only the curl dependency inside the disposable VM =="
# Both apk operations are deliberately bounded by the workflow job timeout.
ssh_guest 'apk update && apk add curl ca-bundle'

echo "== Copy current code and offline smoke tests into guest RAM =="
ssh_input 'cat > /tmp/owrt-netguard' < owrt-netguard
ssh_input 'cat > /tmp/netguard-smoke.sh' < tests/smoke.sh
ssh_input 'cat > /tmp/netguard-state.sh' < lib/netguard-state.sh
ssh_input 'cat > /tmp/netguard-state-test.sh' < tests/state.sh
ssh_input 'cat > /tmp/netguard-monitor' < netguard-monitor
ssh_input 'cat > /tmp/netguard-monitor-test.sh' < tests/monitor.sh
ssh_input 'cat > /tmp/netguard-worker' < netguard-worker
ssh_input 'cat > /tmp/netguard-worker-test.sh' < tests/worker.sh
ssh_input 'cat > /tmp/netguard-path-audit' < netguard-path-audit
ssh_input 'cat > /tmp/netguard-path-audit-test.sh' < tests/path-audit.sh
ssh_input 'cat > /tmp/netguard-endpoint-survey' < netguard-endpoint-survey
ssh_input 'cat > /tmp/netguard-endpoint-survey-test.sh' < tests/endpoint-survey.sh
ssh_input 'cat > /tmp/netguard-init.sh' < service/netguard.init
ssh_input 'cat > /tmp/netguard-procd-test.sh' < tests/ci/procd-guest.sh

echo "== Syntax test using OpenWrt BusyBox shell =="
ssh_guest 'sh -n /tmp/owrt-netguard && sh -n /tmp/netguard-smoke.sh && sh -n /tmp/netguard-state.sh && sh -n /tmp/netguard-state-test.sh && sh -n /tmp/netguard-monitor && sh -n /tmp/netguard-monitor-test.sh && sh -n /tmp/netguard-worker && sh -n /tmp/netguard-worker-test.sh && sh -n /tmp/netguard-path-audit && sh -n /tmp/netguard-path-audit-test.sh && sh -n /tmp/netguard-endpoint-survey && sh -n /tmp/netguard-endpoint-survey-test.sh && sh -n /tmp/netguard-init.sh && sh -n /tmp/netguard-procd-test.sh'

echo "== Run deterministic smoke tests inside genuine OpenWrt 25.12 =="
ssh_guest 'sh /tmp/netguard-smoke.sh /tmp/owrt-netguard'
ssh_guest 'sh /tmp/netguard-state-test.sh /tmp/netguard-state.sh'
ssh_guest 'sh /tmp/netguard-monitor-test.sh /tmp/netguard-monitor /tmp/netguard-state.sh'
ssh_guest 'sh /tmp/netguard-worker-test.sh /tmp/netguard-worker /tmp/netguard-state.sh'
ssh_guest 'sh /tmp/netguard-path-audit-test.sh /tmp/netguard-path-audit'
ssh_guest 'sh /tmp/netguard-endpoint-survey-test.sh /tmp/netguard-endpoint-survey'

echo "== Run real one-shot probe in VM; endpoint reachability is informational =="
# A CI runner is NOT representative of Crimea or any ISP. Any meaningful
# diagnostic RESULT is valid, but a missing utility/unhandled runtime error isn't.
ssh_guest 'sh /tmp/owrt-netguard check >/tmp/netguard-result.txt 2>&1; rc=$?; cat /tmp/netguard-result.txt; grep -q "^RESULT: " /tmp/netguard-result.txt && test "$rc" -le 1'

echo "== Exercise procd service lifecycle in disposable OpenWrt guest =="
ssh_guest 'sh /tmp/netguard-procd-test.sh'

echo "PASS: OpenWrt 25.12 VM syntax, smoke tests, one-shot checks and procd lifecycle"
