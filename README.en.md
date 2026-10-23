# owrt-netguard

[Русский](README.md)

A small, independent OpenWrt project I started planning to better understand why an Internet connection fails and where the problem actually lies.

The idea came from a recurring problem on my own routers: the Internet would go down, and [Podkop](https://github.com/itdoginfo/podkop) diagnostics would report DNS errors. In several cases, the real issue turned out to be upstream at the ISP. Similar symptoms, however, can also come from the router itself, DNS, routing, or a VPN. A single service's error message does not always tell you where to start looking.

OpenWrt already has tools for connectivity checks, statistics, and connection recovery. They serve their own purposes, but I wanted something slightly different: a way to correlate checks across network layers, distinguish root causes from secondary symptoms, and retain an incident history. That is how the idea for NetGuard emerged.

Although the original problem involved Podkop and VPNs, I did not want to build another Podkop-specific tool. NetGuard is intended to be a standalone monitor for different OpenWrt setups, with room for carefully controlled recovery features later.

## Status

**The repository now includes an experimental IPv4 check, an in-memory incident state machine, a manual monitor and a procd-compatible worker. There is no stable release or installer yet.**

`owrt-netguard check` provides one-shot IPv4 diagnostics. The separate `netguard-worker` supports periodic polling but is not installed or started automatically; it remains disabled by default. Neither changes DNS, firewall rules, routing or other services.

### Try the prototype

On an OpenWrt router with `curl`, download the current source into `/tmp` and run it with a shell:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/owrt-netguard/main/owrt-netguard \
  -o /tmp/owrt-netguard
sh /tmp/owrt-netguard check
```

The temporary file is not installed or enabled at boot. Missing dependencies produce an error; the script does not install anything. To check a different logical WAN:

```sh
OWRT_NETGUARD_WAN=wan2 sh /tmp/owrt-netguard check
```

The prototype uses `ubus`, `jsonfilter`, `ip`, `curl`, `nslookup` with built-in timeout/retry options (`-timeout`/`-retry`) and standard BusyBox tools. `nft` is optional and is used to identify destinations selected by Podkop's current nft set.

Current features: WAN state, several HTTPS probes using explicitly pinned IPs and TLS validation, plus multiple external DNS resolvers. **TLS/HTTP server reachability and a healthy endpoint response are distinct**: for example, Yandex returning HTTP 404 confirms a server response but is not counted as a healthy endpoint. Strict endpoint checks currently use Cloudflare (`/cdn-cgi/trace`, HTTP 200) and the Google DNS API (`/resolve?name=example.com&type=A`, HTTP 200); Yandex and Quad9 are transport-only probes until stable response contracts have been confirmed. Additional HTTPS checks stop after two valid health responses, and DNS checks after two answers. More targets are checked when needed.

Statuses include `HEALTHY_SAMPLED` (only the sampled paths), `WAN_INITIALIZING` (netifd is configuring WAN), `WAN_NO_L3`, `PARTIAL_REACHABILITY`, `LOCAL_DNS_UNAVAILABLE`, `EXTERNAL_DNS_UNCONFIRMED`, `DNS_PATH_UNCONFIRMED` and `UNKNOWN_ROUTE`. Failed or skipped probes prevent an unconditional healthy result.

**Limitations:** IPv4 only; HTTPS/DNS endpoints can already be configured through UCI. Failure of all selected endpoints does not prove an ISP outage or a payment-related restriction. Captive-portal classification is not yet implemented. `curl --interface`, pinned IPs and unmarked routing do not prove bypass of nftables/PBR, and external DNS probes are not strictly WAN-bound. Incident history, notifications and Recovery are not implemented. Previous hardware tests passed on AX6000/OpenWrt 24.10.5; the latest startup changes have not yet been field-tested.

The manual [OpenWrt 25.12.5 QEMU workflow](tests/ci/README.md) is active. Both [run #1](https://github.com/SVTagan/owrt-netguard/actions/runs/38820425380) and [run #2](https://github.com/SVTagan/owrt-netguard/actions/runs/39973225284) passed. The second run covered **16 smoke cases, 55 state transitions, startup grace in the worker and the real procd lifecycle**. The latest changes have not yet been field-tested on the AX6000; no physical OpenWrt 25.12 hardware test has taken place.

### Custom probe targets (optional)

Built-in HTTPS and DNS targets are the default. You can override them **without editing the script** using a UCI configuration at `/etc/config/netguard`. The UCI package name is `netguard`: UCI identifiers cannot contain hyphens.

See the [example configuration](examples/netguard) for two independent lists:

- `list https 'name|IPv4|TLS-host|path|expected_HTTP_code'` — strict HTTPS endpoint response; use `-` in place of a code for transport-only reachability.
- `list dns 'name|IPv4'` — plain DNS resolver.

Each list replaces its own defaults; an omitted list continues to use built-in targets. Each list is limited to 12 entries. Invalid entries fail explicitly rather than silently falling back to a different target pool.

To **test in RAM without flash writes**, download the sample to `/tmp`:

```sh
mkdir -p /tmp/netguard-config
curl -fsSL https://raw.githubusercontent.com/SVTagan/owrt-netguard/main/examples/netguard \
  -o /tmp/netguard-config/netguard
OWRT_NETGUARD_CONFIG_DIR=/tmp/netguard-config sh /tmp/owrt-netguard check
```

**Limitation:** service-provider portals, captive portals and allowlisted sites may remain reachable when general Internet access is restricted. The prototype does **not yet classify limited-access probes**. Do not include them as ordinary HTTP 200 health checks or they could produce a false `HEALTHY_SAMPLED`.

Offline smoke tests: `sh tests/smoke.sh ./owrt-netguard` (16 scenarios, including pending WAN setup and invalid UCI data).

### Experimental incident correlation

A separate [shell state library](lib/netguard-state.sh) accepts normalized `check` results and determines when an incident opens, changes classification, and resolves. Provisional thresholds are three consecutive failures of the same class and two confirmed healthy observations. DNS symptoms do not open a second incident while a WAN incident is active. An unknown result does not count as recovery.

The library is now connected to `check` by a separate [bounded foreground monitor](netguard-monitor). It runs a specified number of diagnostic cycles, prints state transitions and exits. **This is not an installed background service**: there is no boot-time startup, persistent flash journal, network recovery or state retention across restarts. Thresholds and intervals remain provisional.

To try three cycles with a 10-second pause on OpenWrt, download all three files into `/tmp`:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/owrt-netguard/main/owrt-netguard -o /tmp/owrt-netguard
curl -fsSL https://raw.githubusercontent.com/SVTagan/owrt-netguard/main/lib/netguard-state.sh -o /tmp/netguard-state.sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/owrt-netguard/main/netguard-monitor -o /tmp/netguard-monitor
sh /tmp/netguard-monitor 3 10
```

The monitor requires an explicit number of cycles (1–30). The interval defaults to 30 seconds. Output includes `SAMPLE`, `STATE` and transition events `OPEN`, `RECLASSIFIED` and `RESOLVED`. Diagnostic command errors become `PROBE_ERROR` instead of being mistaken for proven network outages. Incident state exists **only within the running process**.

Tests: `sh tests/state.sh ./lib/netguard-state.sh` and `sh tests/monitor.sh ./netguard-monitor ./lib/netguard-state.sh`. The state library passed **43 transitions** on a physical AX6000 with OpenWrt 24.10.5. The integrated manual monitor subsequently completed **three consecutive** `HEALTHY_SAMPLED → HEALTHY` cycles and exited cleanly. Failure cases have only been checked with simulated data, not by deliberately disconnecting WAN. The updated WAN initialization logic passed [QEMU/OpenWrt 25.12.5 run #2](https://github.com/SVTagan/owrt-netguard/actions/runs/39973225284) but has not yet been field-tested on the AX6000.

### Experimental service layer (do not install yet)

A [foreground worker](netguard-worker) and [procd init script](service/netguard.init) have been prepared. Starting, stopping and restarting the worker under **real procd** passed in a disposable QEMU/OpenWrt 25.12.5 guest; they have not been installed on physical OpenWrt hardware. Do not copy the init script into `/etc/init.d` or enable boot startup yet.

The [sample UCI config](examples/netguard) sets `monitor_enabled=0` by default. A future explicit enablement will be required before procd starts the worker. The default 30-second interval follows each completed check. Generic `startup_grace=90` seconds suppresses premature fault classification while WAN initializes, independently of Podkop or VPN. After the deadline, missing L3 is treated as an ordinary WAN symptom. Bounded manual runs disable grace by default, but may use `NETGUARD_STARTUP_GRACE` (0–300). procd would supervise the foreground process with rate-limited respawns.

The worker writes an atomic current-state snapshot only to **RAM** (`/tmp/netguard-runtime/status`) and emits incident transition events. It does not persist per-probe history to flash. A crash can leave stale RAM state; this is **not yet a complete `status` CLI**.

To exercise the new worker **without installing a service**, download it into `/tmp` and run three bounded cycles:

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/owrt-netguard/main/netguard-worker -o /tmp/netguard-worker
NETGUARD_CHECK_PATH=/tmp/owrt-netguard NETGUARD_STATE_PATH=/tmp/netguard-state.sh \
  sh /tmp/netguard-worker --cycles 3 10
cat /tmp/netguard-runtime/status
```

Current copies of `/tmp/owrt-netguard` and `/tmp/netguard-state.sh` are required. The `--forever` mode is intended solely for an explicitly enabled future procd service; **do not use it on a production router yet**. Offline tests: `sh tests/worker.sh ./netguard-worker ./lib/netguard-state.sh`. The [procd lifecycle test](tests/ci/procd-guest.sh) passed in QEMU/OpenWrt 25.12.5 (disabled start, explicit enable, RAM snapshot, stop and restart). The second QEMU run passed the new startup-grace scenarios.

### Exploratory regional endpoint survey

A separate manual [`netguard-endpoint-survey`](netguard-endpoint-survey) tool gathers evidence for choosing future RU and international endpoints. Its targets are **candidates, not approved monitoring defaults**. Russian sites may redirect, change IP addresses or exceed the download limit, and overseas targets may be intentionally blocked on some networks. None of these observations alone proves an ISP outage.

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/owrt-netguard/main/netguard-endpoint-survey -o /tmp/netguard-endpoint-survey
sh -n /tmp/netguard-endpoint-survey
sh /tmp/netguard-endpoint-survey --profile all
```

The survey accepts `--profile ru` (five websites grouped as `ru_base`: `ya.ru`, `mail.ru`; `ru_diverse`: `reg.ru`, `nic.ru`, `timeweb.com`) and `--profile international` (the three proven VPN Failover probe URLs at Google gstatic, Apple and Mozilla, using their respective HTTP/body contracts). **These are survey filters, not yet production NetGuard profiles**.

The script uses IPv4, `curl --interface if!<wan-device> --noproxy '*'` with TLS verification, and reports `remote_ip`, HTTP status, timing, response size and the **unmarked** route to the resolved IP. It uses the router's existing DNS; it does not follow redirects, and bounds individual transfers to 8 seconds and 128 KiB. `REDIRECT`, `BODY_LIMIT`, `CONTRACT_MISMATCH` and `ERROR` are distinct observations, none of which proves an ISP outage. Even `MATCHED` validates only this endpoint's HTTP/TLS contract — it cannot establish a conclusively direct WAN path through nftables/PBR.

For custom research targets, use `--file /tmp/targets` with lines in `group|name|https://host/path|expected_http|expected_body` format. Groups are `ru_base`, `ru_diverse`, `international`; HTTP expectations are `200`, `204`, `2xx`, `any`; use `-` for no body token. There is a 16-target maximum. The tool never modifies the file. Proposed production UCI profiles `Russia`/`International`/`Custom` are **not yet implemented**.

This one-shot tool does not start services, change DNS, UCI, firewall rules or routes, or write persistent logs. It sends HTTPS GET requests to the listed public sites and uses a temporary RAM file for expected response-token checks. The deterministic test `sh tests/endpoint-survey.sh ./netguard-endpoint-survey` is wired into the manual OpenWrt 25.12 QEMU workflow but **has not yet been executed there**.

### Experimental WAN path audit

A separate manual [`netguard-path-audit`](netguard-path-audit) command now gathers **read-only routing evidence**, not proof of the route followed by any individual packet. It does not depend on Podkop or other third-party software: it reads standard OpenWrt `ubus`, `jsonfilter`, `ip` output and optional `nft` rules. It **does not change** interfaces, routes or firewall rules.

```sh
curl -fsSL https://raw.githubusercontent.com/SVTagan/owrt-netguard/main/netguard-path-audit -o /tmp/netguard-path-audit
sh -n /tmp/netguard-path-audit
sh /tmp/netguard-path-audit
```

The default destination is `1.1.1.1` (one current HTTPS diagnostic IP); another IPv4 address can be supplied as the first argument, and `OWRT_NETGUARD_WAN` selects another logical WAN. The audit reports whether an **unmarked route** matches that WAN, whether additional IPv4 routing-policy rules exist, and whether nftables contains `route`/`nat` output hooks. These signals do not prove that this particular packet was intercepted.

`PATH_AUDIT: ROUTE_MATCH_ONLY` does **not** mean the actual WAN path was conclusively verified. Netfilter OUTPUT, policy routing and other mechanisms can change packet handling after an ordinary route lookup. `ROUTE_MISMATCH` means the unmarked route chose another interface; `INSUFFICIENT_EVIDENCE` means not enough information is available. The audit makes no network requests and never attributes an outage to the ISP on this evidence alone.

The command is **not invoked by the recurring worker** and does not continuously poll nftables. Its deterministic `sh tests/path-audit.sh ./netguard-path-audit` test is included in the manual QEMU workflow but **has not yet been run there**.

## Development direction

### Monitoring and diagnostics

Planned capabilities include:

- WAN, interface, and routing state checks;
- independent external IP connectivity checks that do not rely solely on the local DNS stack;
- separate checks of upstream and local DNS;
- detection of degraded states and correlation of related failures into a single incident;
- incident history with outage and recovery timestamps;
- notifications when connectivity fails or recovers.

Diagnostics should distinguish observed facts from possible causes. For example, failed external connectivity checks alone do not prove that the ISP is at fault.

### Extensibility

The core monitor is intended to work without Podkop, sing-box, or a specific VPN. Optional adapters may later provide visibility into individual network components.

### Connectivity recovery

A future, **explicitly enabled** Recovery mode may perform controlled actions when a local failure has been confirmed, verify the result, and roll back safely when necessary.

The default behavior is intended to be **monitor-only**. Direct Internet fallback (fail-open) must not be enabled without the user's consent: it can change the expected routing and privacy policy. Restrictive policies must be available for traffic that should never bypass its protected path.

**Recovery has not been implemented.**

## Compatibility

Target OpenWrt releases for development and validation:

- OpenWrt **24.10.x** (`opkg`);
- OpenWrt **25.12.x** (`apk`).

The intended implementation is lightweight and based on standard OpenWrt mechanisms, without mandatory heavyweight runtime dependencies.

These are **compatibility targets, not claims of fully tested support**. Physical AX6000/OpenWrt 24.10.5 checks and a QEMU/OpenWrt 25.12.5 procd lifecycle run previously passed. The startup changes passed the second QEMU regression, but have not yet been tested on the AX6000; physical OpenWrt 25.12 remains untested.

## Design principles

- No required dependency on a specific VPN, proxy, or third-party routing system.
- Clear separation of connectivity diagnostics and recovery actions.
- Low router overhead and conservative flash writes.
- Protection against false alarms and repeated notifications.
- No automatic routing changes in monitor-only mode.
- Predictable behavior during WAN outages, reboots, and recovery.

## Related projects

`owrt-netguard` is intended to be a standalone tool. It does not replace:

- [podkop-vpn-failover](https://github.com/SVTagan/podkop-vpn-failover) — automatic failover between backup AmneziaWG tunnels used by Podkop;
- [podkop-guard](https://github.com/SVTagan/podkop-guard) — validated Last Known Good list and cache protection for Podkop.

Future integration is possible but will not be required by the core monitor.

## License

MIT — see [LICENSE](LICENSE).
