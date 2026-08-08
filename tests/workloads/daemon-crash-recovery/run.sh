#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"
source "${_workload_dir}/library/oci.sh"

_bundle="${_volume_root}/daemon-crash-recovery/bundle"
_export_name="nscell-oci-export-${_workload_resource_id:-daemon-crash-recovery}"
_docker_volume="/var/lib/nscell/work/docker/${_daemon_crash_recovery_id}"

__cleanup() {
  sudo systemctl reset-failed nscell-daemon.service >/dev/null 2>&1 || true
  sudo systemctl start nscell-daemon.service >/dev/null 2>&1 || true
  __remove_oci_container "$_oci_runtime_root" "$_daemon_crash_recovery_id"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__wait_for_pid_exit() {
  local _pid="$1"
  local _label="$2"
  local _deadline=$((SECONDS + 20))

  while ((SECONDS <= _deadline)); do
    if ! sudo test -d "/proc/${_pid}"; then
      return 0
    fi
    sleep 0.2
  done
  echo "${_label} process ${_pid} did not exit" >&2
  return 1
}

__assert_recovered_state() {
  local _container_pid="$1"

  __wait_for_pid_exit "$_container_pid" "orphaned container init"
  sudo test ! -e "${_oci_runtime_root}/${_daemon_crash_recovery_id}"
  if __container_capability_exists "$_daemon_crash_recovery_id"; then
    echo "container capability survived daemon crash recovery" >&2
    return 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs |
    grep -F "/${_daemon_crash_recovery_id}"; then
    echo "VirtFS mount survived daemon crash recovery" >&2
    return 1
  fi
  if sudo test -e "$_docker_volume"; then
    echo "managed volume survived daemon crash recovery: ${_docker_volume}" >&2
    return 1
  fi
  if [[ "$(sudo cat "${_bundle}/rootfs/var/lib/docker/recovered.txt")" != "recovery-v1" ]]; then
    echo "managed volume contents were not recovered into the rootfs" >&2
    return 1
  fi
}

__create_and_start() {
  sudo rm -f "${_bundle}/init.pid"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_daemon_crash_recovery_id"
  sudo nscell --root "$_oci_runtime_root" start "$_daemon_crash_recovery_id"
  sudo nscell --root "$_oci_runtime_root" state "$_daemon_crash_recovery_id" |
    jq -e '.status == "running" and .pid > 0' >/dev/null
}

__main() {
  local _container_pid _daemon_pid

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd jq
  __require_cmd systemctl
  __assert_nscell_ready
  __init_ci_dirs
  trap __cleanup EXIT

  __cleanup
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' \
    "$_export_name"
  sudo install -d -m 0700 "${_bundle}/rootfs/var/lib/docker"

  __log "creating an active container with durable daemon-managed state"
  __create_and_start
  _container_pid="$(sudo cat "${_bundle}/init.pid")"
  sudo test -d "/proc/${_container_pid}"
  __container_capability_exists "$_daemon_crash_recovery_id"
  sudo findmnt -rn -T "/var/lib/nscellfs/${_daemon_crash_recovery_id}" -o FSTYPE |
    grep -Eq '^fuse(\.nscellfs)?$'
  sudo nscell --root "$_oci_runtime_root" exec \
    "$_daemon_crash_recovery_id" /bin/sh -c \
    'printf recovery-v1 > /var/lib/docker/recovered.txt'
  if [[ "$(sudo cat "${_docker_volume}/recovered.txt")" != "recovery-v1" ]]; then
    echo "container write did not reach the managed volume" >&2
    exit 1
  fi

  __log "killing the daemon without running its shutdown reconciliation"
  _daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
  if [[ ! "$_daemon_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "invalid daemon MainPID: ${_daemon_pid}" >&2
    exit 1
  fi
  sudo systemctl kill \
    --kill-whom=main \
    --signal=SIGKILL \
    nscell-daemon.service
  __wait_for_pid_exit "$_daemon_pid" "daemon"
  sudo test -d "/proc/${_container_pid}"
  sudo test -f "${_docker_volume}/recovered.txt"

  __log "restarting the daemon and validating persisted-state recovery"
  sudo systemctl reset-failed nscell-daemon.service
  sudo systemctl start nscell-daemon.service
  __assert_nscell_ready
  __assert_recovered_state "$_container_pid"

  __log "reusing the recovered container ID"
  __create_and_start
  sudo nscell --root "$_oci_runtime_root" state "$_daemon_crash_recovery_id" |
    jq -e '.status == "running" and .pid > 0' >/dev/null
  sudo nscell --root "$_oci_runtime_root" delete --force "$_daemon_crash_recovery_id"
  __assert_nscell_ready

  trap - EXIT
  __cleanup
  echo "daemon-crash-recovery-validation-ok"
}

__main "$@"
