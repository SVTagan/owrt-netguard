# OpenWrt 25.12 CI tests

This directory contains a **active, manually triggered** QEMU test harness for an official OpenWrt 25.12.5 x86_64 system image.

- `openwrt-25.12-qemu.sh` downloads the official ext4 image, verifies its pinned SHA-256, boots it under QEMU, checks release metadata and `apk`, installs a temporary test dependency inside the disposable VM, runs BusyBox syntax checks, offline diagnostic smoke tests, incident-state tests, bounded foreground monitor tests and RAM-worker simulation tests, then executes one real `check` probe. The guest also performs **real procd start/stop/restart tests** using a deterministic mock `check` inside the disposable VM (no service on any physical router).
- `workflow-openwrt-25.12.yml.example` is a reference copy of the active workflow at `.github/workflows/openwrt-25.12.yml`. Only `workflow_dispatch` is enabled, with no `push`, `pull_request` or scheduled triggers.
- The job has a 12-minute timeout, one x86_64 VM, no runner cache and no uploaded artifacts. Guest serial logs are printed in the job log for debugging.
- The guest runs isolated inside GitHub Actions: **no real router is touched**.
- The VM checks guest userland/CLI compatibility, not MediaTek/Cudy drivers, real-world ISP restrictions, Podkop integration or network path independence.
- The selected OpenWrt image is pinned to 25.12.5; updating the release requires updating both its URL and checksum in the runner script.

**Status:** [Run #1 completed successfully](https://github.com/SVTagan/owrt-netguard/actions/runs/38820425380) on October 16, 2026: 15 smoke cases, 46 incident transitions, monitor/worker integration and actual procd lifecycle. Subsequent changes add `WAN_INITIALIZING` and monotonic startup grace: **these have not yet been tested in the VM or on physical hardware**. A successful x86_64 VM run does not validate OpenWrt 25.12 on other architectures or real Podkop configurations.

Reference: https://openwrt.org/docs/guide-user/virtualization/qemu

**Security:** Only use the default empty root password in the disposable, isolated test VM, never on a real Internet-exposed OpenWrt system.
