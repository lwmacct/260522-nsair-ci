# Container Runtime CI Probe

This public repository probes whether GitHub-hosted runners can execute
host-level container runtime tests.

The workflow intentionally does not mirror any product repository CI. It checks
only the resources needed by runtime validation:

- passwordless sudo and systemd-managed Docker
- Docker daemon restart and custom runtime registration
- privileged container mount behavior
- BTF, bpffs, and active BPF LSM
- ID-mapped bind mounts and overlayfs on top of the mapped mount

When manually dispatching the workflow, enable `debug_tmate` to open an SSH
session on the GitHub-hosted runner before the probe runs.

`NSCell CI Gate Mode` validates binaries extracted from a public GHCR image,
for example `ghcr.io/lwmacct/260522-nscell:v0.33.260701`. The runtime setup,
gate check, diagnostics, and workload flow live in this repository under
`scripts/ci.sh` and `ci/runtime/test/`.

All migrated runtime workloads are stored in `ci/runtime/test/workloads/`.
The workflow discovers and runs every workload in parallel by default, so each
workload gets its own runner, Docker daemon, systemd services, logs, and
artifact. A manual run may provide a space-separated `workloads` value to
isolate one or more failing workloads; an empty value always means the full
suite.

The workflow is always started through `workflow_dispatch`, either manually or
by the product release workflow. Every run has a caller-supplied `release_id`,
so the product workflow can locate the exact run and wait for its result. The
run and its billing, matrix jobs, logs, and artifacts therefore remain in this
public repository. It
installs ORAS, fetches the selected linux/amd64 image manifest and layers,
extracts `/usr/local/bin/nscell`, then installs the binary and the
`nscell-daemon.service` systemd unit on the runner.

`gate_mode=ci` runs on GitHub-hosted `ubuntu-24.04` runners and validates the
complete workload matrix with the non-enforcing in-memory gate. Release strict
validation uses `gate_mode=strict`, the `container-security-policy` workload,
and runner labels `["self-hosted","linux","x64","nscell-bpf-lsm"]`. A runner
with that label must boot a kernel whose active LSM list includes `bpf`; strict
validation requires a loaded, enforcing, audited BPF LSM gate and never falls
back to CI mode.
