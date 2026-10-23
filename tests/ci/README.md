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

Reference: https://openwrt.org/docs/guide-user/virtualization/qemu

**Security:** Only use the default empty root password in the disposable, isolated test VM, never on a real Internet-exposed OpenWrt system.
