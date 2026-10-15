#!/bin/sh
# OpenWrt 25.12 guest-only procd lifecycle test.
# The test mutates ONLY the disposable QEMU guest filesystem.
# A deterministic fake probe isolates process supervision from WAN reachability.
set -eu

test -r /etc/openwrt_release
command -v ubus >/dev/null 2>&1
test -r /tmp/netguard-worker
test -r /tmp/netguard-state.sh
test -r /tmp/netguard-init.sh

install -d /usr/lib/netguard /usr/libexec/netguard
cp /tmp/netguard-state.sh /usr/lib/netguard/netguard-state.sh
cp /tmp/netguard-worker /usr/libexec/netguard/netguard-worker

# The service checks a fixed /usr/bin path. Use an isolated deterministic stub:
# HTTPS/DNS tests have already been exercised separately in this same VM.
cat > /usr/bin/owrt-netguard <<'EOF'
#!/bin/sh
printf 'RESULT: HEALTHY_SAMPLED\n'
exit 0
EOF
chmod 755 /usr/bin/owrt-netguard

cp /tmp/netguard-init.sh /etc/init.d/netguard
chmod 755 /etc/init.d/netguard

cat > /etc/config/netguard <<'EOF'
config netguard 'main'
    option monitor_enabled '0'
    option interval '10'
    option wan 'wan'
EOF

# Nothing from this test should remain scheduled for startup.
[ ! -e /etc/rc.d/S95netguard ] || {
    echo 'FAIL: service unexpectedly enabled on boot' >&2
    exit 1
}
uci -q get netguard.main.monitor_enabled | grep -qx 0
uci -q get netguard.main.interval | grep -qx 10

cleanup() {
    /etc/init.d/netguard stop >/dev/null 2>&1 || :
}
trap cleanup EXIT HUP INT TERM

echo '== procd: disabled-by-default service =='
/etc/init.d/netguard start
sleep 1
[ ! -e /tmp/netguard-runtime/status ] || {
    echo 'FAIL: disabled service started the worker' >&2
    exit 1
}
echo 'PASS: disabled service did not start worker'

echo '== procd: explicit start after UCI enable =='
uci set netguard.main.monitor_enabled=1
uci commit netguard
/etc/init.d/netguard start

# BusyBox ash and procd should initialize the first state sample quickly.
ready=0
i=0
while [ "$i" -lt 25 ]; do
    if [ -r /tmp/netguard-runtime/status ] &&
       grep -qx 'running=1' /tmp/netguard-runtime/status &&
       grep -qx 'phase=HEALTHY' /tmp/netguard-runtime/status &&
       grep -qx 'result=HEALTHY_SAMPLED' /tmp/netguard-runtime/status; then
        ready=1
        break
    fi
    i=$((i + 1))
    sleep 1
done
[ "$ready" -eq 1 ] || {
    echo 'FAIL: enabled procd worker did not publish HEALTHY state' >&2
    cat /tmp/netguard-runtime/status 2>/dev/null || :
    ubus call service list '{"name":"netguard","verbose":true}' || :
    exit 1
}
echo 'PASS: procd-launched worker published a RAM snapshot'

echo '== procd: stop and clean termination =='
/etc/init.d/netguard stop
stopped=0
i=0
while [ "$i" -lt 15 ]; do
    if grep -qx 'running=0' /tmp/netguard-runtime/status 2>/dev/null; then
        stopped=1
        break
    fi
    i=$((i + 1))
    sleep 1
done
[ "$stopped" -eq 1 ] || {
    echo 'FAIL: worker did not write a stopped snapshot' >&2
    cat /tmp/netguard-runtime/status 2>/dev/null || :
    exit 1
}
echo 'PASS: procd stop signaled worker and RAM snapshot has running=0'

echo '== procd: restart, then disable =='
/etc/init.d/netguard start
restarted=0
i=0
while [ "$i" -lt 15 ]; do
    if grep -qx 'running=1' /tmp/netguard-runtime/status 2>/dev/null; then
        restarted=1
        break
    fi
    i=$((i + 1))
    sleep 1
done
[ "$restarted" -eq 1 ] || {
    echo 'FAIL: second explicit start did not restart worker' >&2
    exit 1
}
/etc/init.d/netguard stop
uci set netguard.main.monitor_enabled=0
uci commit netguard
/etc/init.d/netguard start
sleep 1
grep -qx 'running=0' /tmp/netguard-runtime/status || {
    echo 'FAIL: disabled service unexpectedly left the worker running' >&2
    exit 1
}
echo 'PASS: second start and final disable'

echo 'PASS: disposable OpenWrt 25.12 procd lifecycle checks'
