# owrt-netguard

[Русский](README.md)

An independent OpenWrt project focused on diagnosing network connectivity and identifying where an Internet outage occurs. Its long-term direction is safe recovery from failures of individual network components.

The goal is not merely to report that the Internet is unavailable, but to help distinguish WAN and upstream connectivity failures from local DNS, routing, VPN, and other service problems.

## Status

**This project is in the design stage. No working release or installation procedure is available yet.**

The initial implementation will focus on diagnostics and event collection. It will not automatically modify network settings.

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
