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

Current features: WAN state, several DNS-independent HTTPS probes using explicitly pinned IPs and TLS validation, plus multiple external DNS resolvers. In healthy conditions it stops after two successful probes of each type; more targets are checked when needed. Example results: `HEALTHY_SAMPLED`, `PARTIAL_REACHABILITY`, `LOCAL_DNS_UNAVAILABLE`, and `DNS_PATH_UNCONFIRMED`.

**Limitations:** IPv4 only. Endpoint reachability and fixed bootstrap addresses have not yet been validated across different networks, including Crimea. Failure of every selected endpoint is not proof of an ISP outage. `--interface` and an unmarked route lookup cannot rule out all nftables/PBR interception. Incident history, notifications and Recovery are not implemented. OpenWrt 25.12 support has not yet been validated on a physical device.

Offline smoke tests: `sh tests/smoke.sh ./owrt-netguard`.

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

These are **compatibility targets, not claims of tested support**. No executable release is available yet.

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
