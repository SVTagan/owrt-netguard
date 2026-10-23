# Endpoint profiles — design contract (draft)

Status: **design-only**, not implemented in `owrt-netguard check` or the procd worker. Do not copy this draft into `/etc/config/netguard`. These are diagnostic design decisions, not a release.

## Why profiles need independent interpretations

The purpose of OWRT NetGuard is to distinguish symptoms attributable to an unavailable WAN/ISP path from symptoms attributable to local DNS, routing, VPN/proxy or filtering. In Russia, a failed Cloudflare/Google/Mozilla probe may mean TSPU blocking rather than failed ISP connectivity. Access to a high-profile Russian domain may persist inside a restrictive allowlist, so the inverse inference is unsafe too.

An HTTP response with correct TLS but unexpected status/body is **positive evidence of some transport reachability**, not a passing probe contract and not proof that the Internet is unrestricted.

## Profiles

- `russia`: the `ru_diverse` group is the principal sampled reachability signal; `ru_base` is evidence that limited/allowlisted connectivity may exist, not proof of unrestricted access. International checks are a separate optional dimension and must **not** cause an otherwise healthy Russian WAN to be classified as down.
- `international`: multiple independent foreign resources act as the primary HTTPS sample; a failed group is only `UNCONFIRMED`, not `ISP_FAULT`, until WAN and independent local evidence are correlated.
- `custom`: explicit user-provided groups/targets and thresholds. The same conservative evidence model is applied; no single endpoint can categorically establish ISP blame.
- During migration, the existing legacy `list https` and `list dns` remain recognized. The current engine and defaults must not change without a tested backward-compatibility path. Do not silently reinterpret the existing five-field UCI HTTPS entries.

Profile selection is user-configured; do not geolocate, infer the user's country, or change profiles automatically.

## Field-test evidence, 2026-10-23, AX6000 / OpenWrt 24.10.5

| Group | Candidate | Actual result | Decision |
| --- | --- | --- | --- |
| ru_base | `https://ya.ru/` | TLS valid, 302 | Reachable, **not** strict 2xx health check; follow-up URL is not known |
| ru_base | `https://mail.ru/` | TLS valid, 302 | Reachable, **not** strict 2xx health check |
| ru_diverse | `https://www.reg.ru/` | TLS valid, 200; 13,602 bytes | Do not count as independent from NIC.RU; body unverified |
| ru_diverse | `https://www.nic.ru/` | TLS valid, 200; 13,602 bytes | Same Runity group as REG.RU, not independent |
| ru_diverse | `https://www.reg.ru/robots.txt` | TLS valid, 200; 13,602 bytes, **no `User-agent` token**, `CONTRACT_MISMATCH` | **Reject as a strict health target** until cause is understood. Possible unexpected/challenge page, unproven |
| ru_diverse | `https://beget.com/robots.txt` | Curl 28 at 3-second connect timeout, HTTP 000 | Not a default until reliably verified |
| ru_diverse | `https://selectel.ru/robots.txt` | TLS valid, 200 + `User-agent`, 1,664 bytes, 231 ms | Verified **on this WAN**, candidate |
| ru_diverse | `https://timeweb.com/robots.txt` | TLS valid, 200 + `User-agent`, 932 bytes, 195 ms | Verified **on this WAN**, candidate |
| international | `www.gstatic.com/generate_204` | TLS valid, 204 | Observed pass, **not** a universal Russian WAN target |
| international | `captive.apple.com/hotspot-detect.html` | TLS valid, 200 + `Success` | Observed pass, optional |
| international | `detectportal.firefox.com/success.txt` | TLS valid, 200 + `success` | Observed pass, optional |

All successful survey IPs used `route_unmarked=MATCHES_WAN`, but this is **not proof of a direct WAN packet path** through nftables/PBR. Survey domain resolution uses the router's configured resolver and may be DNS-dependent.

The verified RU set currently has **only two independently-operated candidates**; a resilient 2-of-3 quorum is **not yet available**. Do not call the selection final or fabricate a third successful resource. Other sites can be added later by the user.

## Proposed target schema (NOT YET PARSED)

Consider a new, distinct UCI option `https_target` instead of overloading legacy `https`:

```text
group|name|tls-hostname|IPv4-or-auto|path|expected-http|expected-body-token-or-dash
```

A distinct name for this UCI field allows supporting legacy five-column pinned-IP entries without incompatible reinterpretation. Pinned IP probes separate remote HTTPS from the local DNS resolver; `auto` FQDN resolution is DNS-dependent and should be identified explicitly in output. A strict TLS verification and the HTTP/body contract are always maintained. Unexpected 3xx/403/451 or an oversized body must be a separately classified endpoint observation, not treated as ISP outage.

Illustration only (not ready for installation):

```text
ru_diverse|selectel|selectel.ru|auto|/robots.txt|200|User-agent
ru_diverse|timeweb|timeweb.com|auto|/robots.txt|200|User-agent
international|gstatic|www.gstatic.com|auto|/generate_204|204|-
international|apple|captive.apple.com|auto|/hotspot-detect.html|200|Success
international|mozilla|detectportal.firefox.com|auto|/success.txt|200|success
```

Additional safely configurable parameters: minimum independent successes, group inclusion and per-target timeout, with bounded input sizes. Initially, the profile should not mutate DNS, routes, nftables or state outside `/tmp`.

## Evaluation and false-alarm safeguards

1. WAN physical/link/L3 diagnostics remain independent of any HTTPS endpoint.
2. Classify **each** HTTPS outcome as (a) verified contract, (b) reachable but contract mismatch/redirect, (c) failure, (d) skipped/unverified route.
3. Count **independent operators**, not mere IPs or domains; two hostnames owned by Runity count once, at most.
4. A healthy `ru_base` with unavailable `ru_diverse` means `POSSIBLE_LIMITED_ACCESS` / insufficient independent proof — not `WAN_DOWN`. International failure alongside working `ru_diverse` is a separate `INTERNATIONAL_UNCONFIRMED` condition.
5. Local DNS health, WAN DNS supplied by ISP (if any), Russian DNS, and international DNS should be evaluated separately. Plain UDP DNS can be blocked, redirected or answered by middleboxes; DNS failure cannot automatically downgrade a confirmed HTTPS path to ISP-down.
6. A single failed independent endpoint must never open an ISP incident. Use the existing state machine's multi-sample hysteresis and a group-level minimum. With fewer than three verified independent RU targets, explicitly report **LIMITED_TARGET_DIVERSITY**.
7. Preserve the existing worker's normalized `RESULT:` contract and state machine until the new classifications and their recovery transitions have tests. Emit detail lines for group evidence separately.

## Implementation/testing sequence

1. Add pure read-only profile/target loading with full input validation and legacy config compatibility; mocked UCI tests for `russia`, `international`, `custom` and invalid configs.
2. Implement grouped HTTPS responses and body tokens, bound time/size limits, `auto` vs pinned DNS distinction, and no false ISP inference.
3. Add synthetic tests for (a) blocked international + RU healthy, (b) allowlist-only, (c) one of two RU down, (d) all independent groups fail, (e) DNS blocked but pinned HTTPS working, (f) routing/Podkop uncertainty, (g) redirects/challenge HTTP 200, and (h) stale/empty UCI.
4. Run local BusyBox ash tests **before** publishing to main; then the manually triggered OpenWrt 25.12 QEMU workflow and opt-in bounded `/tmp` field checks on OpenWrt 24.10.5.
5. Only after these tests consider activating user-configurable profiles in the always-on worker. Installer/autostart remain out of scope until confirmed.

Do not turn `REG.RU/robots.txt` into a passing control merely because it returns HTTP 200. The observed contract mismatch is correct.
