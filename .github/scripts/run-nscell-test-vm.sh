#!/usr/bin/env bash

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/../.." && pwd)"
_image_ref="${1:?usage: run-nscell-test-vm.sh IMAGE_REF MODE [WORKLOADS]}"
_test_mode="${2:-smoke}"
_workloads="${3:-procfs-cpu}"
_binary="${NSCELL_VM_BINARY:?NSCELL_VM_BINARY must point to a built nscell binary}"
_ci_repo="${NSCELL_VM_CI_REPO:?NSCELL_VM_CI_REPO must point to 260522-nscell-ci}"
_oras_binary="${NSCELL_VM_ORAS_BINARY:-$(command -v oras)}"
_run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}"
_resource_id="$(printf '%s' "${_run_id}" | tr -c '[:alnum:]_.-' '-')"
_resource_id="${_resource_id:0:24}"
_vm_name="${NSCELL_VM_NAME:-nscell-test-vm-${_resource_id}}"
_image_alias="${_vm_name}-image"
_image_dir="${RUNNER_TEMP:-/tmp}/nscell-test-vm-${_resource_id}"
_log_dir="${NSCELL_VM_LOG_DIR:-${RUNNER_TEMP:-/tmp}/nscell-test-vm-logs-${_resource_id}}"

__log() {
  printf '\n==> %s\n' "$*" >&2
}

__collect_guest_logs() {
  mkdir -p "${_log_dir}"
  sudo incus exec "${_vm_name}" -- bash -euo pipefail -c '
    {
      uname -a
      cat /sys/kernel/security/lsm || true
      findmnt /sys/fs/bpf || true
      systemctl --no-pager --full status docker.service nscell-daemon.service || true
      systemctl cat nscell-daemon.service || true
      nscell daemon gate status || true
      docker info || true
      docker ps -a || true
      docker images || true
      journalctl --no-pager -u docker.service -u nscell-daemon.service || true
    } 2>&1
    test -f /var/log/nscell-daemon.log && cat /var/log/nscell-daemon.log || true
  ' >"${_log_dir}/guest-diagnostics.log" 2>&1 || true
  sudo incus file pull "${_vm_name}/var/log/nscell-daemon.log" "${_log_dir}/nscell-daemon.log" 2>/dev/null || true
  sudo incus file pull -r "${_vm_name}/data/nscell" "${_log_dir}/data-nscell" 2>/dev/null || true
}

__cleanup() {
  _status=$?
  if [[ ${_status} -ne 0 ]]; then
    __collect_guest_logs
  fi
  sudo incus delete --force "${_vm_name}" 2>/dev/null || true
  sudo incus image delete "${_image_alias}" 2>/dev/null || true
  if [[ ${_status} -ne 0 ]]; then
    __log "VM test failed; diagnostics are in ${_log_dir}"
  fi
  return "${_status}"
}

__wait_for_agent() {
  local _attempt
  for _attempt in $(seq 1 120); do
    if sudo incus exec "${_vm_name}" -- test -f /etc/os-release >/dev/null 2>&1; then
      return 0
    fi
    sleep 5
  done
  return 1
}

__prepare_image() {
  rm -rf "${_image_dir}"
  mkdir -p "${_image_dir}"
  __log "pulling ${_image_ref}"
  oras pull --output "${_image_dir}" "${_image_ref}"
  (
    cd "${_image_dir}"
    sha256sum --check SHA256SUMS
  )
  qemu-img check "${_image_dir}/disk.qcow2"
  sudo incus image import \
    "${_image_dir}/incus.tar.xz" \
    "${_image_dir}/disk.qcow2" \
    --alias "${_image_alias}"
}

__launch_vm() {
  sudo incus init "${_image_alias}" "${_vm_name}" \
    --vm \
    -c security.secureboot=false \
    -c limits.cpu=4 \
    -c limits.memory=8GiB
  sudo incus start "${_vm_name}"
  if ! __wait_for_agent; then
    __collect_guest_logs
    return 1
  fi
}

__copy_inputs() {
  sudo incus file push "${_binary}" "${_vm_name}/opt/nscell.test"
  sudo incus file push "${_oras_binary}" "${_vm_name}/opt/oras.test"
  sudo incus exec "${_vm_name}" -- mkdir -p /opt/nscell-ci
  tar --exclude=.git -C "${_ci_repo}" -cf - . |
    sudo incus exec "${_vm_name}" -- tar -xf - -C /opt/nscell-ci
}

__configure_guest() {
  __log "configuring nscell in ${_vm_name}"
  sudo incus exec "${_vm_name}" -- env NSCELL_TEST_MODE="${_test_mode}" NSCELL_TEST_WORKLOADS="${_workloads}" bash -s <<'EOF'
set -euo pipefail

_test_mode="${NSCELL_TEST_MODE}"
_workloads="${NSCELL_TEST_WORKLOADS}"

install -m 0755 /opt/nscell.test /usr/bin/nscell
rm -f /opt/nscell.test
install -m 0755 /opt/oras.test /usr/local/bin/oras
rm -f /opt/oras.test
nscell version

install -d -m 0755 /etc/docker
_docker_config=/etc/docker/daemon.json
_docker_tmp=/etc/docker/daemon.json.nscell
if test -s "${_docker_config}"; then
  jq '.runtimes = ((.runtimes // {}) | .nscell = {"path": "/usr/bin/nscell", "runtimeArgs": []})' "${_docker_config}" >"${_docker_tmp}"
else
  jq -n '{"runtimes": {"nscell": {"path": "/usr/bin/nscell", "runtimeArgs": []}}}' >"${_docker_tmp}"
fi
install -m 0644 "${_docker_tmp}" "${_docker_config}"
rm -f "${_docker_tmp}"

cat >/etc/systemd/system/nscell-daemon.service <<'UNIT'
[Unit]
Description=nscell-daemon (NSCell VM test host)
Before=docker.service containerd.service

[Service]
Type=notify
ExecStart=/usr/bin/nscell daemon --log /var/log/nscell-daemon.log --gate-mode ci --metrics-listen 127.0.0.1:9618
TimeoutStartSec=45
TimeoutStopSec=90
StartLimitInterval=0
NotifyAccess=main
OOMScoreAdjust=-500
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable nscell-daemon.service
systemctl enable docker.service
systemctl stop nscell-daemon.service docker.service || true
rm -f /run/nscell/daemon.sock /run/nscell/daemon.pid
rm -rf /run/nscell/containers /var/lib/nscellfs/*
mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
grep -qw bpf /sys/kernel/security/lsm
systemctl restart nscell-daemon.service
systemctl restart docker.service

for _attempt in $(seq 1 45); do
  if systemctl is-active --quiet nscell-daemon.service && grep -q 'Ready ...' /var/log/nscell-daemon.log && docker info --format '{{json .Runtimes}}' | jq -e 'has("nscell")' >/dev/null; then
    break
  fi
  sleep 2
done
systemctl is-active --quiet nscell-daemon.service
grep -q 'Ready ...' /var/log/nscell-daemon.log
docker info --format '{{json .Runtimes}}' | jq -e 'has("nscell")' >/dev/null
nscell daemon gate status | jq -e '.mode == "ci" and .enforce == false' >/dev/null

case "${_test_mode}" in
smoke)
  docker run --rm --runtime nscell --pull=always busybox:1.37.0 sh -c 'test "$(uname -m)" = x86_64; test "$(cat /etc/hostname)" != ""; echo nscell-vm-smoke-ok'
  ;;
workloads)
  cd /opt/nscell-ci
  bash scripts/ci.sh install-dependencies
  bash scripts/ci.sh show-host-capabilities
  bash scripts/ci.sh verify-gate
  if [[ -z "${_workloads}" || "${_workloads}" == all ]]; then
    bash scripts/ci.sh run-workloads
  else
    read -r -a _selected_workloads <<<"${_workloads}"
    bash scripts/ci.sh run-workloads "${_selected_workloads[@]}"
  fi
  bash scripts/ci.sh collect-logs || true
  ;;
*)
  echo "unsupported NSCELL_TEST_MODE: ${_test_mode}" >&2
  exit 2
  ;;
esac
EOF
}

__main() {
  test -x "${_binary}"
  test -d "${_ci_repo}"
  case "${_test_mode}" in
  smoke | workloads) ;;
  *)
    echo "unsupported test mode: ${_test_mode}" >&2
    exit 2
    ;;
  esac

  trap __cleanup EXIT HUP INT TERM
  __prepare_image
  __launch_vm
  __copy_inputs
  __configure_guest
  __collect_guest_logs
  __log "${_test_mode} test passed for ${_image_ref}"
}

__main "$@"
