# OpenWrt 25.12 CI tests

This directory contains a **prepared, not yet activated** QEMU test harness for an official OpenWrt 25.12.5 x86_64 system image.

- `openwrt-25.12-qemu.sh` downloads the official ext4 image, verifies its pinned SHA-256, boots it under QEMU, checks release metadata and `apk`, installs a temporary test dependency inside the disposable VM, runs BusyBox syntax checks, offline diagnostic smoke tests, incident-state tests, bounded foreground monitor tests and RAM-worker simulation tests, then executes one real `check` probe. The experimental procd init script receives a **syntax-only** check; the service is not enabled or started.
- `workflow-openwrt-25.12.yml.example` is a **manual-only** GitHub Actions workflow template. To enable it, copy its contents into `.github/workflows/openwrt-25.12.yml` on the repository default branch. The workflow uses `workflow_dispatch`, not `push` or `pull_request`. It will not start until manually triggered.
- The job has a 12-minute timeout, one x86_64 VM, no runner cache and no uploaded artifacts. Guest serial logs are printed in the job log for debugging.
- The guest runs isolated inside GitHub Actions: **no real router is touched**.
- The VM checks guest userland/CLI compatibility, not MediaTek/Cudy drivers, real-world ISP restrictions, Podkop integration or network path independence.
- The selected OpenWrt image is pinned to 25.12.5; updating the release requires updating both its URL and checksum in the runner script.

**Status:** The workflow is a template, not an active Actions workflow. It has not been executed in GitHub Actions yet. Do not claim verified OpenWrt 25.12 compatibility until a real run succeeds.

Reference: https://openwrt.org/docs/guide-user/virtualization/qemu

**Security:** Only use the default empty root password in the disposable, isolated test VM, never on a real Internet-exposed OpenWrt system.
