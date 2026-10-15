# owrt-netguard

[Русский](README.md)

A small, independent OpenWrt project I started planning to better understand why an Internet connection fails and where the problem actually lies.

The idea came from a recurring problem on my own routers: the Internet would go down, and [Podkop](https://github.com/itdoginfo/podkop) diagnostics would report DNS errors. In several cases, the real issue turned out to be upstream at the ISP. Similar symptoms, however, can also come from the router itself, DNS, routing, or a VPN. A single service's error message does not always tell you where to start looking.

OpenWrt already has tools for connectivity checks, statistics, and connection recovery. They serve their own purposes, but I wanted something slightly different: a way to correlate checks across network layers, distinguish root causes from secondary symptoms, and retain an incident history. That is how the idea for NetGuard emerged.

Although the original problem involved Podkop and VPNs, I did not want to build another Podkop-specific tool. NetGuard is intended to be a standalone monitor for different OpenWrt setups, with room for carefully controlled recovery features later.

## Status

**An experimental `owrt-netguard check` prototype is now available in the repository. There is no stable release or installer yet.**

This is a manual, one-shot IPv4 diagnostic tool, not a background monitor. It reads OpenWrt state and performs network probes without restarting services or changing DNS, firewall rules, or routing.

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

Statuses include `HEALTHY_SAMPLED` (only the sampled paths, not the entire Internet), `PARTIAL_REACHABILITY`, `WAN_NO_L3`, `LOCAL_DNS_UNAVAILABLE`, `EXTERNAL_DNS_UNCONFIRMED`, `DNS_PATH_UNCONFIRMED` and `UNKNOWN_ROUTE`. Failed or skipped probes prevent an unconditional healthy result.

**Limitations:** IPv4 only. The endpoint list is currently hard-coded; user-controlled UCI configuration is planned. Endpoint reachability in Crimea and other networks remains unverified. Failure of all selected endpoints does not prove an ISP outage. `--interface` and an unmarked route lookup cannot rule out all nftables/PBR interception, and external `nslookup` traffic is not strictly bound to WAN. Incident history, notifications and Recovery are not implemented. The **previous** prototype ran successfully on a physical AX6000 with OpenWrt 24.10.5; these latest changes still require retesting.

An [OpenWrt 25.12.5 QEMU test harness](tests/ci/README.md) has been prepared for manual GitHub Actions runs, but has not been activated or executed. No physical OpenWrt 25.12 hardware test has taken place.

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

Offline smoke tests: `sh tests/smoke.sh ./owrt-netguard` (15 modeled scenarios, including invalid UCI data).

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

Tests: `sh tests/state.sh ./lib/netguard-state.sh` and `sh tests/monitor.sh ./netguard-monitor ./lib/netguard-state.sh`. An earlier library version passed **43 state transitions** on a physical AX6000 with OpenWrt 24.10.5. The new integrated foreground monitor has not yet been hardware-tested. Local mock scenarios have been exercised; the OpenWrt 25.12 VM has not yet been run.

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

These are **compatibility targets, not claims of fully tested support**. An experimental script is available, but no stable release has been published. An earlier revision ran on OpenWrt 24.10.5 hardware; OpenWrt 25.12 has not yet been verified in QEMU or on hardware.

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
