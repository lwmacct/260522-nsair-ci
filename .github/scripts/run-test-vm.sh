#!/usr/bin/env bash

set -euo pipefail

_test_target="${1:?usage: run-test-vm.sh TEST_TARGET NSCELL_IMAGE}"
_nscell_image="${2:?usage: run-test-vm.sh TEST_TARGET NSCELL_IMAGE}"
_ci_repo="${NSCELL_VM_CI_REPO:?NSCELL_VM_CI_REPO must point to nscell-ci checkout}"
_image_dir="${NSCELL_VM_IMAGE_DIR:?NSCELL_VM_IMAGE_DIR must point to a verified VM artifact}"
_image_ref="${NSCELL_VM_IMAGE_REF:?NSCELL_VM_IMAGE_REF is required for diagnostics}"
_vm_cpu="${NSCELL_VM_CPU:?NSCELL_VM_CPU is required}"
_vm_memory="${NSCELL_VM_MEMORY:?NSCELL_VM_MEMORY is required}"
_registry_username="${NSCELL_REGISTRY_USERNAME:-${GITHUB_ACTOR:-github-actions[bot]}}"
_registry_token="${NSCELL_REGISTRY_TOKEN:-}"
_run_id="${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}-${_test_target}"
_resource_id="$(printf '%s' "${_run_id}" | tr -c '[:alnum:]_.-' '-')"
_resource_id="${_resource_id:0:32}"
_vm_name="${NSCELL_VM_NAME:-test-vm-${_resource_id}}"
_image_alias="${_vm_name}-image"
_share_dir="${RUNNER_TEMP:-/tmp}/test-vm-share-${_resource_id}"
_log_dir="${NSCELL_VM_LOG_DIR:-${RUNNER_TEMP:-/tmp}/test-vm-logs-${_resource_id}}"

__log() {
  printf '\n==> %s\n' "$*" >&2
}

__collect_guest_logs() {
  mkdir -p "${_log_dir}"
  # shellcheck disable=SC2024 # The runner user owns the diagnostics destination.
  sudo incus exec "${_vm_name}" -- bash -euo pipefail -c '
    {
      uname -a
      cat /etc/test-vm-profile || true
      cat /sys/kernel/security/lsm || true
      findmnt /sys/fs/bpf || true
      ip -4 address show || true
      ip -4 route show || true
      cat /etc/resolv.conf || true
      findmnt -T /opt/nscell-ci || true
      ls -ld /opt/nscell-ci || true
      ls -l /opt/nscell-ci/scripts/ci.sh || true
      docker version || true
      oras version || true
      systemctl --no-pager --full status docker.service nscell-daemon.service || true
      systemctl cat nscell-daemon.service || true
      nscell daemon gate status || true
      docker info || true
      docker ps -a || true
      docker images || true
      systemctl --no-pager --full status incus-agent.service || true
      journalctl --no-pager -u incus-agent.service || true
      journalctl --no-pager -u docker.service -u nscell-daemon.service || true
    } 2>&1
    test -f /var/log/nscell-daemon.log && cat /var/log/nscell-daemon.log || true
  ' >"${_log_dir}/guest-diagnostics.log" 2>&1 || true
  sudo incus file pull "${_vm_name}/var/log/nscell-daemon.log" \
    "${_log_dir}/nscell-daemon.log" 2>/dev/null || true
  sudo incus file pull -r "${_vm_name}/data/nscell" \
    "${_log_dir}/data-nscell" 2>/dev/null || true
}

__cleanup() {
  local _status=$?

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
  local _agent_ready=false _contract_ready=false _attempt

  for _attempt in $(seq 1 60); do
    if sudo incus exec "${_vm_name}" -- true >/dev/null 2>&1; then
      _agent_ready=true
      if sudo incus exec "${_vm_name}" -- sh -c '
        test -f /etc/test-vm-profile &&
          test -x /usr/local/bin/oras &&
          test -x /usr/bin/docker
      ' >/dev/null 2>&1; then
        _contract_ready=true
        if sudo incus exec "${_vm_name}" -- test \
          -r /opt/nscell-ci/scripts/ci.sh >/dev/null 2>&1; then
          return 0
        fi
      fi
    fi
    if [[ "${_agent_ready}" == true ]]; then
      sleep 2
    else
      sleep 5
    fi
  done
  if [[ "${_contract_ready}" == true ]]; then
    echo "Incus agent is ready but the CI 9p share was not mounted" >&2
  elif [[ "${_agent_ready}" == true ]]; then
    echo "Incus agent is ready but the standard VM contract is incomplete" >&2
  else
    echo "Incus agent did not become ready within 5 minutes" >&2
  fi
  return 1
}

__import_image() {
  test -s "${_image_dir}/incus.tar.xz"
  test -s "${_image_dir}/disk.qcow2"
  test -s "${_image_dir}/SHA256SUMS"
  sudo incus --quiet image import \
    "${_image_dir}/incus.tar.xz" \
    "${_image_dir}/disk.qcow2" \
    --alias "${_image_alias}"
}

__prepare_share() {
  mkdir -p "${_share_dir}"
  tar --exclude=.git -C "${_ci_repo}" -cf - . |
    tar -xf - -C "${_share_dir}"
  test -x "${_share_dir}/scripts/ci.sh"
  test -d "${_share_dir}/ci/runtime/test"
}

__launch_vm() {
  sudo incus --quiet init "${_image_alias}" "${_vm_name}" \
    --vm \
    -c security.secureboot=false \
    -c limits.cpu="${_vm_cpu}" \
    -c limits.memory="${_vm_memory}"
  sudo incus --quiet config device add \
    "${_vm_name}" ci-source disk \
    source="${_share_dir}" \
    path=/opt/nscell-ci \
    readonly=true \
    io.bus=9p
  sudo incus --quiet start "${_vm_name}"
  __wait_for_agent
}

__check_network() {
  NSCELL_VM_NAME="${_vm_name}" \
    NSCELL_VM_LOG_DIR="${_log_dir}/network" \
    bash "${_ci_repo}/.github/scripts/check-incus-vm-network.sh"
}

__configure_guest() {
  __log "configuring ${_test_target} in ${_vm_name}"
  sudo incus exec "${_vm_name}" -- \
    env \
    NSCELL_TEST_TARGET="${_test_target}" \
    NSCELL_IMAGE="${_nscell_image}" \
    NSCELL_GATE_MODE=strict \
    NSCELL_REGISTRY_USERNAME="${_registry_username}" \
    NSCELL_REGISTRY_TOKEN="${_registry_token}" \
    bash -s <<'EOF'
set -euo pipefail

_test_target="${NSCELL_TEST_TARGET}"
_nscell_image="${NSCELL_IMAGE}"

if [[ -n "${NSCELL_REGISTRY_TOKEN}" ]]; then
  printf '%s' "${NSCELL_REGISTRY_TOKEN}" |
    oras login ghcr.io \
      --username "${NSCELL_REGISTRY_USERNAME}" \
      --password-stdin
fi

mountpoint -q /sys/fs/bpf || mount -t bpf bpf /sys/fs/bpf
grep -qw bpf /sys/kernel/security/lsm
test -x /usr/local/bin/oras
test -x /usr/bin/docker

cd /opt/nscell-ci
export NSCELL_IMAGE="${_nscell_image}"
export NSCELL_IMAGE_PLATFORM=linux/amd64
export NSCELL_CI_TEST_ROOT=/data/nscell
export NSCELL_GATE_MODE=strict
bash scripts/ci.sh setup-runtime-host
bash scripts/ci.sh verify-gate

case "${_test_target}" in
smoke)
  docker pull --platform linux/amd64 busybox:1.37.0
  docker run --rm --runtime nscell --pull=never busybox:1.37.0 sh -c \
    'test "$(uname -m)" = x86_64; test -n "$(cat /etc/hostname)"; echo nscell-vm-smoke-ok'
  ;;
*)
  bash scripts/ci.sh show-host-capabilities
  bash scripts/ci.sh run-workload "${_test_target}"
  bash scripts/ci.sh collect-logs || true
  ;;
esac

if [[ -n "${NSCELL_REGISTRY_TOKEN}" ]]; then
  oras logout ghcr.io || true
fi
EOF
}

__main() {
  if [[ "${_test_target}" != smoke &&
    ! "${_test_target}" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    echo "invalid VM test target: ${_test_target}" >&2
    return 2
  fi
  if [[ "${_test_target}" == all ]]; then
    echo "run-test-vm.sh accepts one concrete workload, not all" >&2
    return 2
  fi
  test -d "${_ci_repo}"
  test -d "${_image_dir}"
  trap __cleanup EXIT HUP INT TERM
  __prepare_share
  __import_image
  __launch_vm
  __check_network
  __configure_guest
  __collect_guest_logs
  __log "${_test_target} test passed for ${_image_ref}"
}

__main "$@"
