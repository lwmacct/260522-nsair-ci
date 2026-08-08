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

_bundle="${_volume_root}/storage-lifecycle/bundle"
_export_name="nscell-storage-export-${_workload_resource_id:-storage-lifecycle}"
_managed_volume_roots=(
  /var/lib/nscell/work/buildkit
  /var/lib/nscell/work/containerd
  /var/lib/nscell/work/docker
  /var/lib/nscell/work/k0s
  /var/lib/nscell/work/kubelet
  /var/lib/nscell/work/rancher-k3s
  /var/lib/nscell/work/rancher-rke2
)

__cleanup() {
  __remove_oci_container "$_oci_runtime_root" "$_storage_lifecycle_id"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__managed_volume_path() {
  local _root="$1"

  printf '%s/%s\n' "$_root" "$_storage_lifecycle_id"
}

__assert_managed_volumes_present() {
  local _root _path

  for _root in "${_managed_volume_roots[@]}"; do
    _path="$(__managed_volume_path "$_root")"
    printf 'storage-managed-volume=%s\n' "$_path"
    sudo test -d "$_path"
  done
}

__wait_for_managed_volume_cleanup() {
  local _deadline=$((SECONDS + 20))
  local _root _path _found

  while ((SECONDS <= _deadline)); do
    _found=false
    for _root in "${_managed_volume_roots[@]}"; do
      _path="$(__managed_volume_path "$_root")"
      if sudo test -e "$_path"; then
        _found=true
        break
      fi
    done
    if [[ "$_found" == "false" ]]; then
      return 0
    fi
    sleep 0.2
  done

  echo "daemon-managed volumes survived rootfs removal" >&2
  for _root in "${_managed_volume_roots[@]}"; do
    _path="$(__managed_volume_path "$_root")"
    sudo find "$_path" -maxdepth 2 -printf '%M %u:%g %p\n' 2>/dev/null || true
  done
  return 1
}

__container_exec() {
  sudo nscell --root "$_oci_runtime_root" exec "$_storage_lifecycle_id" "$@"
}

__assert_container_file() {
  local _path="$1"
  local _expected="$2"
  local _actual

  _actual="$(__container_exec cat "$_path")"
  printf 'storage-container-file=%s:%s\n' "$_path" "$_actual"
  if [[ "$_actual" != "$_expected" ]]; then
    echo "unexpected container file ${_path}: got ${_actual}, want ${_expected}" >&2
    return 1
  fi
}

__assert_host_file() {
  local _path="$1"
  local _expected="$2"
  local _actual

  _actual="$(sudo cat "$_path")"
  printf 'storage-host-file=%s:%s\n' "$_path" "$_actual"
  if [[ "$_actual" != "$_expected" ]]; then
    echo "unexpected host file ${_path}: got ${_actual}, want ${_expected}" >&2
    return 1
  fi
}

__create_and_start() {
  sudo rm -f "${_bundle}/init.pid"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_storage_lifecycle_id"
  sudo nscell --root "$_oci_runtime_root" start "$_storage_lifecycle_id"
}

__main() {
  local _docker_volume

  if [[ "${1:-}" == "cleanup" ]]; then
    __cleanup
    return
  fi

  __require_cmd docker
  __require_cmd jq
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
  printf 'seed-v1\n' | sudo tee "${_bundle}/rootfs/var/lib/docker/seed.txt" >/dev/null
  _docker_volume="$(__managed_volume_path /var/lib/nscell/work/docker)"

  __log "validating managed-volume sync-in and runtime writes"
  __create_and_start
  __assert_managed_volumes_present
  __container_exec /bin/sh -c \
    "awk '\$5 == \"/var/lib/docker\" { found = 1 } END { exit !found }' /proc/self/mountinfo"
  __assert_container_file /var/lib/docker/seed.txt seed-v1
  __assert_host_file "${_docker_volume}/seed.txt" seed-v1
  __container_exec /bin/sh -c 'printf cycle-one > /var/lib/docker/runtime.txt'
  __assert_host_file "${_docker_volume}/runtime.txt" cycle-one

  __log "validating sync-out and same-ID container recreation"
  sudo nscell --root "$_oci_runtime_root" delete --force "$_storage_lifecycle_id"
  __assert_host_file "${_bundle}/rootfs/var/lib/docker/runtime.txt" cycle-one
  sudo test -d "$_docker_volume"

  __create_and_start
  __assert_container_file /var/lib/docker/seed.txt seed-v1
  __assert_container_file /var/lib/docker/runtime.txt cycle-one
  __container_exec /bin/sh -c 'printf cycle-two > /var/lib/docker/runtime.txt'
  __container_exec /bin/sh -c 'printf second-file > /var/lib/docker/second.txt'
  sudo nscell --root "$_oci_runtime_root" delete --force "$_storage_lifecycle_id"
  __assert_host_file "${_bundle}/rootfs/var/lib/docker/runtime.txt" cycle-two
  __assert_host_file "${_bundle}/rootfs/var/lib/docker/second.txt" second-file

  __log "validating managed-volume cleanup after rootfs removal"
  __remove_oci_bundle "$_bundle"
  __wait_for_managed_volume_cleanup
  if __container_capability_exists "$_storage_lifecycle_id"; then
    echo "container capability survived storage lifecycle cleanup" >&2
    exit 1
  fi
  if sudo findmnt -rn -t fuse,fuse.nscellfs | grep -F "/${_storage_lifecycle_id}"; then
    echo "VirtFS mount survived storage lifecycle cleanup" >&2
    exit 1
  fi

  trap - EXIT
  __cleanup
  echo "storage-lifecycle-validation-ok"
}

__main "$@"
