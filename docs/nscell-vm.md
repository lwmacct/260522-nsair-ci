# NSCell Ubuntu VM validation

This repository owns a dedicated Ubuntu 24.04 AMD64 Incus VM image for NSCell
runtime validation. The image is built with `distrobuilder`, while the runner
installs Incus from the signed Zabbly source at `pkgs.zabbly.com`.

The image definition is `images/test-vm.yaml`. It contains the Incus VM
agent, the Docker runtime stack, FUSE and idmap utilities, diagnostics, and a
guest GRUB command line that enables the BPF LSM. It does not contain an
NSCell binary; each test workflow accepts an nscell OCI image, extracts its
AMD64 binary on the GitHub runner, and exposes it to a disposable VM through a
read-only Incus disk share.

The image workflow publishes an OCI artifact to:

```text
ghcr.io/lwmacct/260522-nscell-ci:nscell-test-ubuntu24.04-amd64-vm
```

GHCR artifacts are imported into Incus with ORAS before the VM is started.
The artifact contains `incus.tar.xz`, `disk.qcow2`, and `SHA256SUMS`.

## Workflows

- `Build NSCell test VM image` runs on image changes or manually. It
  builds the split VM artifact, checks the qcow2 file, and publishes the stable
  tag without starting a guest.
- `Test NSCell VM smoke` is a manual entry point (and is dispatched by the
  nscell release workflow when a release needs VM coverage). It checks BPF LSM,
  nscell daemon readiness, Docker runtime registration, and one `busybox`
  container.
- `Test NSCell VM workloads` is a manual entry point for the external workload
  suite. `workloads` accepts a space-separated list such as
  `procfs-cpu systemd-pid1`, or `all` for the complete suite.

Both test workflows accept `nscell_image`. The nscell release workflow passes
an immutable digest, while manual runs can select any published nscell image.
The smoke workflow also pulls and exports its BusyBox image on the runner, so
the guest setup and smoke test do not depend on guest network access. Test
assets and a CI repository snapshot are exposed through one read-only Incus
`9p` directory share. The runner explicitly selects `9p` because the default
`virtiofs` transport conflicts with PCI allocation on GitHub-hosted runners.

The VM runner always uses KVM and is AMD64-only. Failed runs upload the guest
daemon log, systemd/Docker diagnostics, and `/data/nscell` test logs.
