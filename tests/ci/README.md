# OpenWrt 25.12 CI tests

This directory contains an **active, manually triggered** QEMU test harness for an official OpenWrt 25.12.5 x86_64 system image.

- `openwrt-25.12-qemu.sh` downloads the official ext4 image, verifies its pinned SHA-256, boots it under QEMU, checks release metadata and `apk`, installs a temporary test dependency inside the disposable VM, runs BusyBox syntax checks, offline diagnostic smoke tests, incident-state tests, bounded foreground monitor tests, RAM-worker simulations and a mocked read-only WAN path-audit test, then executes one real `check` probe. The guest also performs **real procd start/stop/restart tests** using a deterministic mock `check` inside the disposable VM (no service on any physical router).
- `workflow-openwrt-25.12.yml.example` is a reference copy of the active workflow at `.github/workflows/openwrt-25.12.yml`. Only `workflow_dispatch` is enabled, with no `push`, `pull_request` or scheduled triggers.
- The job has a 12-minute timeout, one x86_64 VM, no runner cache and no uploaded artifacts. Guest serial logs are printed in the job log for debugging.
- The guest runs isolated inside GitHub Actions: **no real router is touched**.
- The VM checks guest userland/CLI compatibility, not MediaTek/Cudy drivers, real-world ISP restrictions, Podkop integration or network path independence.
- The selected OpenWrt image is pinned to 25.12.5; updating the release requires updating both its URL and checksum in the runner script.

**Status:** [Run #1](https://github.com/SVTagan/owrt-netguard/actions/runs/38820425380) passed on October 16, 2026 (15 smoke cases, 46 transitions, worker and procd). [Run #2](https://github.com/SVTagan/owrt-netguard/actions/runs/39973225284) passed on October 23, 2026 (16 smoke cases, 55 transitions, `WAN_INITIALIZING`, monotonic startup grace, worker snapshots and actual procd lifecycle). These results validate this test matrix on x86_64 QEMU only; physical AX6000 and other architectures still need field tests for the new logic. Neither run proves the diagnosis of real ISP outages or Podkop/PBR path independence.

**Pending rerun:** After successful run #2, the repository gained `netguard-path-audit` and `tests/path-audit.sh`. Their syntax and deterministic scenarios are wired into the next manual QEMU run, but are not covered by run #2. The audit does not capture or trace actual WAN packets.

Reference: https://openwrt.org/docs/guide-user/virtualization/qemu

**Security:** Only use the default empty root password in the disposable, isolated test VM, never on a real Internet-exposed OpenWrt system.
