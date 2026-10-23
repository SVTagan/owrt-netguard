# Opt-in WAN-only check (experimental)

## Goal and boundaries

`netguard-wan-check` answers a narrow question: **are known external HTTPS endpoints reachable via the router's selected WAN interface without consulting the configured DNS or proxy?** It is an optional bridge from the existing validated grouped HTTPS sampler to the existing `RESULT:` / incident state-machine contract.

It is **not** a diagnosis of which ISP device, physical line, power supply or transit operator caused an outage. Inability to contact every pinned endpoint **does not prove an upstream fault**: stale addresses, local firewall and policy routing, carrier filtering and TLS errors can produce the same symptom. Conversely, `ip route get` and `curl --interface if!wan` do **not prove actual packet egress through WAN** in the presence of nftables route/output rules. No physical interface, DNS, proxy, firewall or route configuration is changed.

### Safety and compatibility

- **Explicit opt-in** by choosing the new `netguard-wan-check` script as the diagnostic command. The legacy `owrt-netguard check`, `netguard-worker`, state library, and procd init script have **not been altered**.
- The worker already supports `NETGUARD_CHECK_PATH`; the new command accepts its unchanged `check` argument and emits the familiar `RESULT:` field. This is **only for bounded tests at this stage**. Do not install it as the default service or enable `monitor_enabled=1`.
- Requires an explicit `russia`, `international` or `custom` profile, at least two **different pinned IPv4 addresses** in the active group, and **no** `auto` address in any configured HTTPS target. The old implicit `legacy` mode is refused. This fails closed instead of silently reintroducing system DNS.
- Uses `netguard-profile-probe` for certificate validation, strict HTTP/body contracts, pinned `--resolve`, `curl -q --noproxy '*'`, `--interface if!<WAN>`, connection/total-time limits and checked actual `remote_ip` for pinned endpoints. Each target uses its own curl process, so no interface-sharing connection-reuse is needed.
- Uses netifd `ubus` to identify WAN `up/pending/l3_device`, and reads physical carrier where available. IPv4 only. No autostart, package installation, persistent logs or configuration changes.
- The preview IPs for Selectel and Timeweb were physically tested on one Russian WAN in October 2026, but are **not** stable defaults and do not guarantee site/ISP independence. Do not treat two matching endpoints as definitive evidence of unrestricted Internet, especially during regional allowlisting.

### Result mapping

| Observation | Normalized `RESULT:` | Meaning |
| --- | --- | --- |
| 2+ strict matches in active group through unmarked WAN route | `HEALTHY_SAMPLED` | At least two selected WAN-bound HTTPS samples confirmed |
| 1 strict match, or nonmatching TLS/HTTP reachability, or only allowlisted-base reachability | `PARTIAL_REACHABILITY` | Some independent external reachability, but full quorum absent |
| All configured pinned endpoints fail, with no positive response or path uncertainty | `EXTERNAL_REACHABILITY_UNCONFIRMED` | Unknown cause; **not** `ISP_DOWN` |
| Some routes cannot be confirmed or curl cannot bind to WAN (no positive response) | `UNKNOWN_ROUTE` | Evidence is insufficient; do not open an ISP-fault incident |
| WAN pending/no L3 / lost physical carrier | `WAN_INITIALIZING` / `WAN_NO_L3` / `WAN_LINK_DOWN` | Local WAN symptoms; cause unknown |
| Invalid, missing, legacy or DNS-dependent profile | Exit 2, no `RESULT:` | Caller worker should classify `PROBE_ERROR`, not network failure |

The existing state machine requires three matching fault samples to open an incident, and two healthy samples for recovery. A `CONNECTIVITY` incident is not proof of ISP responsibility.

### Manual read-only test using a temporary profile

On a router with `curl`, `ubus`, `jsonfilter`, `ip`, `uci` and standard BusyBox, copy the following four current files into `/tmp` from the **same pinned Git commit**: `netguard-wan-check`, `netguard-profile-probe`, `lib/netguard-profiles.sh`, `examples/netguard-wan.preview`. Then:

```sh
mkdir -p /tmp/netguard-wan-preview
cp /tmp/netguard-wan.preview /tmp/netguard-wan-preview/netguard
sh -n /tmp/netguard-wan-check
OWRT_NETGUARD_CONFIG_DIR=/tmp/netguard-wan-preview \
NETGUARD_PROFILES_LIB=/tmp/netguard-profiles.sh \
NETGUARD_PROFILE_PROBE=/tmp/netguard-profile-probe \
sh /tmp/netguard-wan-check check
```

**Do not copy the preview to /etc/config** or use it as a permanent monitor without revalidating addresses. If all pinned endpoints fail, read the `TARGET` lines rather than concluding the ISP is down.

For optional bounded worker integration (never use `--forever` during experiments), download the existing worker and state library into `/tmp` as well:

```sh
OWRT_NETGUARD_CONFIG_DIR=/tmp/netguard-wan-preview \
NETGUARD_PROFILES_LIB=/tmp/netguard-profiles.sh \
NETGUARD_PROFILE_PROBE=/tmp/netguard-profile-probe \
NETGUARD_CHECK_PATH=/tmp/netguard-wan-check \
NETGUARD_STATE_PATH=/tmp/netguard-state.sh \
NETGUARD_RUNTIME_DIR=/tmp/netguard-wan-runtime \
sh /tmp/netguard-worker --cycles 3 0
```

The bounded worker creates **RAM-only** status snapshots under `/tmp/netguard-wan-runtime`. It never starts a service.

### Validation status

Deterministic [`tests/wan-check.sh`](../tests/wan-check.sh) covers healthy/partial/all-failed samples, RU allowlist isolation, international/custom group quorum, WAN pending/down, route uncertainty, interface bind error, duplicate/stale-input risks and invalid configuration. The test is wired into the manually triggered QEMU/OpenWrt 25.12.5 workflow. **No new QEMU run or physical AX6000 test has yet validated this adapter.** Earlier successful QEMU #6 and AX6000 HTTPS tests covered its underlying components, not this adapter.

References: [libcurl interface binding](https://curl.se/libcurl/c/CURLOPT_INTERFACE.html), [curl CLI documentation](https://curl.se/docs/manpage.html), [OpenWrt netifd ubus status](https://openwrt.org/docs/guide-developer/ubus/network), [OpenWrt firewall4 output routing hook](https://github.com/openwrt/firewall4/blob/master/root/usr/share/firewall4/templates/ruleset.uc).
