# OpenWrt 25.12 CI tests

This directory contains an **active, manually triggered** QEMU test harness for an official OpenWrt 25.12.5 x86_64 system image.

- `openwrt-25.12-qemu.sh` downloads the official ext4 image, verifies its pinned SHA-256, boots it under QEMU, checks release metadata and `apk`, installs a temporary test dependency inside the disposable VM, runs BusyBox syntax checks, offline diagnostic smoke tests, incident-state tests, bounded foreground monitor tests, RAM-worker simulations, a mocked read-only WAN path-audit test and a mocked RU/international HTTPS endpoint-survey test, then executes one real `check` probe. The guest also performs **real procd start/stop/restart tests** using a deterministic mock `check` inside the disposable VM (no service on any physical router).
- `workflow-openwrt-25.12.yml.example` is a reference copy of the active workflow at `.github/workflows/openwrt-25.12.yml`. Only `workflow_dispatch` is enabled, with no `push`, `pull_request` or scheduled triggers.
- The job has a 12-minute timeout, one x86_64 VM, no runner cache and no uploaded artifacts. Guest serial logs are printed in the job log for debugging.
- The guest runs isolated inside GitHub Actions: **no real router is touched**.
- The VM checks guest userland/CLI compatibility, not MediaTek/Cudy drivers, real-world ISP restrictions, Podkop integration or network path independence.
- The selected OpenWrt image is pinned to 25.12.5; updating the release requires updating both its URL and checksum in the runner script.

**Status:** [Run #1](https://github.com/SVTagan/owrt-netguard/actions/runs/38820425380) passed on October 16, 2026 (15 smoke cases, 46 transitions). [Run #2](https://github.com/SVTagan/owrt-netguard/actions/runs/39973225284) passed on October 23 (16 smoke cases, 55 transitions and procd). [Run #3](https://github.com/SVTagan/owrt-netguard/actions/runs/39990869415) **passed on October 23, 2026**: 16 smoke scenarios, 55 transitions, WAN route audit, endpoint survey, profile-loader mocks and real guest UCI (`russia` with Selectel/Timeweb), worker and procd. This validates the test matrix on x86_64 QEMU only; the profile loader has not yet been tested on physical AX6000 and no run proves ISP fault attribution or nftables/PBR path independence.

**Run #3 coverage:** The new `netguard-path-audit` and `netguard-endpoint-survey` mock suites both passed; the path audit does not trace live packets and the endpoint survey does not query the real regional candidate URLs inside CI.


**Profile loader:** The standalone `netguard-profiles` CLI, `lib/netguard-profiles.sh` UCI loader and `tests/profiles.sh` **passed run #3**, including actual guest UCI parsing of `examples/netguard-profiles.preview`. Field testing on physical AX6000 is still pending. Legacy `check` and procd worker remain unchanged.

**Next manually triggered regression (not yet run):** `netguard-profile-probe` and `tests/profile-probe.sh` are now copied into guest RAM, syntax-checked and exercised with deterministic mocks under OpenWrt BusyBox ash. New scenarios verify RU/intl isolation, possible allowlist-only access, pinned IPv4 success despite system DNS failure, strict response contracts and PBR route uncertainty. Local BusyBox ash/dash/bash suites passed; these new files are **not** part of prior successful run #3. The existing legacy `check` and procd lifecycle are unchanged.

**Run #4 infrastructure failure, not a code-test failure (2026-10-23):** [GitHub Actions run #4](https://github.com/SVTagan/owrt-netguard/actions/runs/40029556683) stopped at `apk update` inside the disposable OpenWrt VM before any new offline test executed. The `x86_64/base/packages.adb` feed returned a `wget` transport error (`Operation not permitted`, incomplete index). The newly added `netguard-profile-probe` therefore **was not evaluated by that run**. Afterward, `tests/ci/openwrt-25.12-qemu.sh` was changed to run syntax + deterministic offline tests before any package installation and to attempt `apk update && apk add curl ca-bundle` up to 3 times with a short delay. If all attempts fail, CI still fails with an explicit infrastructure message; the failure is not silently treated as a passing product test. **The modified workflow has not yet been rerun.**

Reference: https://openwrt.org/docs/guide-user/virtualization/qemu

**Security:** Only use the default empty root password in the disposable, isolated test VM, never on a real Internet-exposed OpenWrt system.
