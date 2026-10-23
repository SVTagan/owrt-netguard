# Endpoint profiles — design contract (draft)

Status (October 23, 2026): **phase 1 read-only profile loading implemented** in [`lib/netguard-profiles.sh`](../lib/netguard-profiles.sh) and [`netguard-profiles`](../netguard-profiles). Profiles are **not integrated** into `owrt-netguard check` or the procd worker. The current diagnostic engine and its legacy UCI lists are unchanged. The new loader does not make network requests, install services or modify network/UCI configuration. Not a release.

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

## Phase 1 profile loader and validation

Implementation: `lib/netguard-profiles.sh` (sourceable loader) + `netguard-profiles` (read-only CLI). Validation is enforced for groups (`ru_base`, `ru_diverse`, `international`), unique ASCII names, DNS hostnames, IPv4 or `auto`, sanitized HTTPS paths including query parameters, exact HTTP status or `2xx`, and optional ASCII response token. A maximum of 12 targets is enforced. Invalid UCI data is an explicit error; it never silently falls back to another target list.

```sh
# From a source checkout, no configuration installed:
NETGUARD_PROFILES_LIB=./lib/netguard-profiles.sh sh ./netguard-profiles show --profile russia
NETGUARD_PROFILES_LIB=./lib/netguard-profiles.sh sh ./netguard-profiles show --profile international

# Preview from a disposable config directory only:
mkdir -p /tmp/netguard-profile-preview
cp examples/netguard-profiles.preview /tmp/netguard-profile-preview/netguard
OWRT_NETGUARD_CONFIG_DIR=/tmp/netguard-profile-preview \
  NETGUARD_PROFILES_LIB=./lib/netguard-profiles.sh sh ./netguard-profiles validate
```

When no explicit profile is selected, the inspector reports `LEGACY_UNCHANGED`: the existing `list https` and `list dns` are not reinterpreted. If UCI selects a profile, `list https_target` overrides its candidate list; `custom` requires explicit targets. To demonstrate RU candidates without a UCI file, pass `--profile russia`. Built-in targets are provisional *research candidates*, **not a guaranteed RU-wide health profile**; `russia` currently prints `LIMITED_TARGET_DIVERSITY`.

Test status: `tests/profiles.sh` passed locally under BusyBox `ash` 1.37, `dash` and `bash`. [OpenWrt 25.12.5 QEMU workflow run #3](https://github.com/SVTagan/owrt-netguard/actions/runs/39990869415) **passed** (2026-10-23): mock tests, startup/worker regressions, endpoint survey, WAN path audit, **actual guest UCI parsing** of the preview profile, and `procd` lifecycle. Real UCI reported `PROFILE selected=russia source=uci+uci-targets targets=2` and group counts `ru_diverse=2`. The files have not yet been field-tested on physical AX6000. The new format remains deliberately **inactive** in the monitoring engine.

## Target schema (NOW PARSED BY STANDALONE LOADER ONLY)

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

## Phase 2 — isolated grouped HTTPS sampler (experimental)

The [`netguard-profile-probe`](../netguard-profile-probe) command now consumes profile definitions from `lib/netguard-profiles.sh` and makes read-only, bounded, IPv4 HTTPS GET requests. This is a **manual opt-in research tool**, not a replacement for `owrt-netguard check` or the `procd` worker.

```sh
# Example from an unpacked checkout, using a preview file in /tmp:
OWRT_NETGUARD_CONFIG_DIR=/tmp/netguard-profile-preview \
NETGUARD_PROFILES_LIB=./lib/netguard-profiles.sh \
sh ./netguard-profile-probe

# Explicitly choose the candidate profile without a UCI config:
OWRT_NETGUARD_CONFIG_DIR=/tmp/empty-netguard-config \
NETGUARD_PROFILES_LIB=./lib/netguard-profiles.sh \
sh ./netguard-profile-probe --profile russia
```

The CLI deliberately rejects the legacy profile so no unattended monitor changes behavior by accident. On WAN-down it returns a `PROFILE_OBSERVATION: WAN_UNREADY` without any probes, **not** a judgement about the ISP. Individual targets show `MATCHED`, `CONTRACT_MISMATCH`, `REDIRECT`, `BODY_LIMIT`, `TIMEOUT`, `DNS_FAILED`, `TLS_FAILED`, `SKIPPED_ROUTE` or `PATH_UNCONFIRMED`; group lines report successful contracts, transport-only evidence, failures and path uncertainty.

- Only HTTPS is used, with verified certificates, `curl -4 --noproxy '*'`, explicit interface binding, no redirect following and at most 4 seconds to connect, 8 seconds total, 32 KiB response body **per target**. A max of 12 HTTPS targets is enforced by the loader; worst-case all targets can take roughly 96 seconds. The manual tool is **not invoked periodically**.
- `auto` resolves TLS hostnames via existing system DNS, therefore does **not** isolate DNS failure from WAN failure. A pinned IPv4 uses `--resolve` to avoid DNS for that HTTPS destination. A pinned destination with a known different unmarked route is skipped; an unmarked route match is **still not proof** that nftables/PBR left the packet untouched.
- `MATCHED` requires curl exit 0, TLS verification 0, matching expected HTTP code (or `2xx`) and the body token when configured. HTTP 200 without the token, HTTP redirect, oversized body or failure of a foreign endpoint is never counted as a good health contract.
- A confirmed sample requires the unmarked route to match the configured WAN. Route mismatch/unknown is classed as path uncertainty; the code does not modify or bypass policy routing, kill switches, DNS, network interfaces or firewall.
- `russia` derives `RU_REACHABLE_SAMPLED` from at least two matching RU-diverse targets, `RU_PARTIALLY_CONFIRMED` from one, `POSSIBLE_LIMITED_ACCESS` from RU-base transport when RU-diverse is unconfirmed, or `RU_ACCESS_UNCONFIRMED` otherwise. **These are observations, not a proof of carrier/ISP failure or of true target ownership independence.** Foreign endpoint failures are reported separately and do not downgrade working RU targets.
- `international` and `custom` have separate sampled/unconfirmed outputs. There is deliberately no `RESULT:` for the old state machine, and no RAM incident history or remediation.

Local deterministic [`tests/profile-probe.sh`](../tests/profile-probe.sh) passed under BusyBox `ash` 1.37, `dash` and `bash`. The synthetic scenarios include blocked international probes with healthy RU, an allowlist-only network, 1/2 RU target failure, all failures, response-body mismatch/redirect, oversized response, policy-route mismatch, pinned HTTPS success while auto-DNS fails and TLS failure. The test is wired into the manually triggered OpenWrt 25.12.5 QEMU workflow but **has not yet been run in QEMU or on the physical AX6000**. Such offline tests do not establish real-world endpoint reachability.

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
2. **Implemented as isolated manual experimental sampler:** grouped HTTPS responses and body tokens, bounded time/size limits, `auto` vs pinned DNS distinction and conservative non-ISP classifications. Still awaiting a fresh QEMU run and physical field trial.
3. Add synthetic tests for (a) blocked international + RU healthy, (b) allowlist-only, (c) one of two RU down, (d) all independent groups fail, (e) DNS blocked but pinned HTTPS working, (f) routing/Podkop uncertainty, (g) redirects/challenge HTTP 200, and (h) stale/empty UCI.
4. Run local BusyBox ash tests **before** publishing to main; then the manually triggered OpenWrt 25.12 QEMU workflow and opt-in bounded `/tmp` field checks on OpenWrt 24.10.5.
5. Only after these tests consider activating user-configurable profiles in the always-on worker. Installer/autostart remain out of scope until confirmed.

Do not turn `REG.RU/robots.txt` into a passing control merely because it returns HTTP 200. The observed contract mismatch is correct.
