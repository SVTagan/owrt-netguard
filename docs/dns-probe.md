# Experimental DNS diagnostics

The manual [`netguard-dns-probe`](../netguard-dns-probe) is an **independent, read-only research tool**. It does not run as part of `owrt-netguard check`, `netguard-profile-probe`, the incident state machine, or the procd worker.

The purpose is to distinguish evidence for **local loopback DNS** (e.g. dnsmasq/AdGuard configured on 127.0.0.1) from evidence for **external Russian** and **international** plaintext DNS, without confusing DNS failures with ISP outages. IPv4 only.

### Defaults and profiles

| Profile | Local loopback | Russian resolvers | International resolvers |
| --- | --- | --- | --- |
| `russia` (default) | 127.0.0.1 | Yandex `77.88.8.8`, SkyDNS `193.58.251.251` | None |
| `international` | 127.0.0.1 | None | Cloudflare `1.1.1.1`, Google `8.8.8.8` |
| `all` | 127.0.0.1 | Yandex, SkyDNS | Cloudflare, Google |
| `custom` | User supplied | User supplied | User supplied |

**These are experimental DNS query targets, not authoritative proof of availability across Russia.** SkyDNS and the international resolvers have not yet been verified from the user's WAN for this command. The default query domain is `example.com` with record type A. A DNS response from a public resolver may be blocked, intercepted, altered, or returned by another resolver; direct plaintext DNS is not authenticated. In particular, **do not infer ISP failure from unavailable international DNS**.

### Manual usage

```sh
sh -n ./netguard-dns-probe
sh ./netguard-dns-probe --profile russia
sh ./netguard-dns-probe --profile international
```

Override with a readable text file, up to eight targets, with one entry per line:

```text
# group|name|IPv4_resolver|FQDN
local|local|127.0.0.1|example.com
ru|my_ru_dns|77.88.8.8|example.com
international|my_intl_dns|1.1.1.1|example.com
```

Use `--file /tmp/dns-targets --profile custom` for custom target lists. This is not yet UCI integration with the HTTPS profiles. The tool validates names, IPv4, group and query domain before sending individual requests, but runs probes sequentially and has no background process.

### Semantics and limits

- Uses BusyBox-compatible `nslookup -timeout=3 -retry=1 -type=A name server`. Requires an IPv4 A answer **after** the `Name:` section, not merely a resolver banner; an actual DNS answer may still be spoofed.
- Only reads the standard `network.interface.wan` state from `ubus` and the ordinary `ip -4 route get` to each external resolver; if the unmarked route is not selected WAN or WAN is down, external queries are skipped. `nslookup` **cannot be bound to WAN** through this interface and nftables/PBR can still intercept even matched routes.
- The local target always probes `127.0.0.1:53`. Its failure **does not establish** that the router's actual DNS chain is unavailable: other ports and upstream DNS/DoH configurations are possible. An independent lookup of the configured WAN DNS supplied by the ISP is not yet implemented; `ubus` may have no advertised DNS servers at all (for example, static WAN).
- Each output contains per-target result `ANSWER`, `UNCONFIRMED`, or `SKIPPED_ROUTE` plus group counters. Aggregate statuses are `LOCAL_AND_EXTERNAL_DNS_ANSWER_SAMPLED`, `LOCAL_DNS_ANSWER_SAMPLED`, `EXTERNAL_DNS_ANSWER_LOCAL_UNCONFIRMED`, and `DNS_ANSWERS_UNCONFIRMED`.
- None of these statuses changes an HTTPS-group observation or the legacy `RESULT:` / state machine. No proof of ISP fault, captive-portal state, white-list limits or DNS responder identity is claimed.
- No DNS/network/firewall/UCI changes, no service install/start, no persistent logs. No continuous querying: only manual invocation. On the user's router files are intended for `/tmp` only.

### Validation

The deterministic [`tests/dns-probe.sh`](../tests/dns-probe.sh) passed locally under BusyBox `ash`, `dash`, and `bash` using mocked `nslookup`, `ubus`, `ip`, and `jsonfilter`. Scenarios: local resolver failure with external success, blocked RU or international DNS with local success, all probes failing, spoof-like `Server` header without an A-record answer, mismatched route, WAN down, custom targets, and unsafe input validation.

The mocked scenarios **passed [OpenWrt 25.12.5 QEMU workflow run #6](https://github.com/SVTagan/owrt-netguard/actions/runs/40032413103)** (2026-10-23), along with all prior regressions and the real one-shot legacy `HEALTHY_SAMPLED` check. The new DNS probe also **passed a physical Redmi AX6000 / OpenWrt 24.10.5 field test** on 2026-10-24, using pinned QEMU-pass commit `539e345d6290671aef3afbfe2f127d715af71cdc`. `sh -n` and the on-device deterministic test returned PASS. The read-only `--profile russia` query returned: local `127.0.0.1` `ANSWER`, Russian Yandex `77.88.8.8` `ANSWER`, SkyDNS `193.58.251.251` `ANSWER`, `DNS_SUMMARY failed=0 skipped=0`, `DNS_OBSERVATION: LOCAL_AND_EXTERNAL_DNS_ANSWER_SAMPLED`. Both external resolver IPs had `route_unmarked=MATCHES_WAN`. This confirms sample DNS responses on that network only, **not** resolver identity, UDP/53 packet path, upstream DoH health or filtering behavior under fault conditions.
