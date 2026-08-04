#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/../../.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"
source "${_workload_dir}/library/oci.sh"

_bundle="${_volume_root}/rootfs-event-recovery/bundle"
_export_name="nscell-rootfs-event-export-${_workload_resource_id:-rootfs-event-recovery}"
_docker_volume="/var/lib/nscell/work/docker/${_rootfs_event_recovery_id}"

__cleanup() {
  sudo systemctl reset-failed nscell-daemon.service >/dev/null 2>&1 || true
  sudo systemctl start nscell-daemon.service >/dev/null 2>&1 || true
  __remove_oci_container "$_oci_runtime_root" "$_rootfs_event_recovery_id"
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

__kill_daemon() {
  local _daemon_pid

  _daemon_pid="$(systemctl show --property MainPID --value nscell-daemon.service)"
  if [[ ! "$_daemon_pid" =~ ^[1-9][0-9]*$ ]]; then
    echo "invalid daemon MainPID: ${_daemon_pid}" >&2
    return 1
  fi
  sudo systemctl kill \
    --kill-whom=main \
    --signal=SIGKILL \
    nscell-daemon.service
  __wait_for_pid_exit "$_daemon_pid" daemon
}

__create_and_start() {
  sudo rm -f "${_bundle}/init.pid"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_rootfs_event_recovery_id"
  sudo nscell --root "$_oci_runtime_root" start "$_rootfs_event_recovery_id"
  sudo nscell --root "$_oci_runtime_root" state "$_rootfs_event_recovery_id" |
    jq -e '.status == "running" and .pid > 0' >/dev/null
}

__assert_recovery_blocked() {
  local _status

  _status="$(sudo nscell daemon status)"
  jq -e \
    --arg _id "$_rootfs_event_recovery_id" \
    '.admission == "Degraded"
      and .acceptingNewContainers == false
      and any(.resourceLeases[]?;
        .id == $_id and .phase == "Finalizing" and .cleanupError != "")' \
    <<<"$_status" >/dev/null
  sudo test -e "$_docker_volume"
  sudo test ! -e "${_oci_runtime_root}/${_rootfs_event_recovery_id}"
  if __container_capability_exists "$_rootfs_event_recovery_id"; then
    echo "container capability survived lost rootfs recovery" >&2
    return 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs | grep -F "/${_rootfs_event_recovery_id}"; then
    echo "VirtFS mount survived lost rootfs recovery" >&2
    return 1
  fi
}

__assert_recovery_complete() {
  local _status

  _status="$(sudo nscell daemon status)"
  jq -e \
    --arg _id "$_rootfs_event_recovery_id" \
    'all(.sessions[]?; .id != $_id)
      and all(.resourceLeases[]?; .id != $_id)' \
    <<<"$_status" >/dev/null
  sudo test ! -e "$_docker_volume"
  sudo test ! -e "${_oci_runtime_root}/${_rootfs_event_recovery_id}"
  if __container_capability_exists "$_rootfs_event_recovery_id"; then
    echo "container capability survived completed rootfs recovery" >&2
    return 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs | grep -F "/${_rootfs_event_recovery_id}"; then
    echo "VirtFS mount survived completed rootfs recovery" >&2
    return 1
  fi
}

__wait_for_recovery_complete() {
  local _deadline=$((SECONDS + 30))

  while ((SECONDS <= _deadline)); do
    if __assert_recovery_complete; then
      return 0
    fi
    sleep 0.2
  done
  echo "rootfs cleanup did not converge" >&2
  return 1
}

__recreate_bundle() {
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    '["/bin/sh", "-c", "trap exit TERM INT; while :; do sleep 1; done"]' \
    "$_export_name"
  sudo install -d -m 0700 "${_bundle}/rootfs/var/lib/docker"
}

__assert_lost_rootfs_recovery() {
  local _container_pid

  __recreate_bundle
  __create_and_start
  _container_pid="$(sudo cat "${_bundle}/init.pid")"
  sudo nscell --root "$_oci_runtime_root" exec "$_rootfs_event_recovery_id" /bin/sh -c \
    'printf rootfs-event-recovery > /var/lib/docker/recovered.txt'
  sudo test -f "${_docker_volume}/recovered.txt"

  __log "killing daemon before removing the container rootfs"
  __kill_daemon
  __remove_oci_bundle "$_bundle"
  sudo systemctl reset-failed nscell-daemon.service
  sudo systemctl start nscell-daemon.service
  __assert_nscell_ready
  __wait_for_pid_exit "$_container_pid" "orphaned container init"
  __assert_recovery_blocked

  __log "restoring the rootfs path and replaying blocked recovery"
  __recreate_bundle
  __kill_daemon
  sudo systemctl reset-failed nscell-daemon.service
  sudo systemctl start nscell-daemon.service
  __assert_nscell_ready
  __assert_recovery_complete
}

__assert_replayed_cleanup() {
  __log "replaying cleanup after a live rootfs removal"
  __recreate_bundle
  __create_and_start
  sudo nscell --root "$_oci_runtime_root" delete --force "$_rootfs_event_recovery_id"
  __remove_oci_bundle "$_bundle"
  __wait_for_recovery_complete

  sudo nscell --root "$_oci_runtime_root" delete --force "$_rootfs_event_recovery_id"
  sudo nscell --root "$_oci_runtime_root" delete --force "$_rootfs_event_recovery_id"
  __assert_recovery_complete
}

__main() {
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
  __assert_lost_rootfs_recovery
  __assert_replayed_cleanup

  trap - EXIT
  __cleanup
  echo "rootfs-event-recovery-validation-ok"
}

__main "$@"
