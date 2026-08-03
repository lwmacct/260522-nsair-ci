#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2024,SC2154

set -euo pipefail

_workload_path="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_workload_dir="$(cd "${_workload_path}/../.." && pwd)"
_repo_root="$(cd "${_workload_dir}/../../.." && pwd)"

cd "$_repo_root"

source "${_workload_dir}/library/env.sh"
source "${_workload_dir}/library/readiness.sh"
source "${_workload_dir}/library/images.sh"
source "${_workload_dir}/library/oci.sh"

_bundle="${_volume_root}/resource-update/bundle"
_export_name="nscell-resource-update-export-${_workload_resource_id:-resource-update}"
_initial_memory_bytes=268435456
_updated_memory_bytes=134217728
_initial_cpu_quota=200000
_updated_cpu_quota=50000
_cpu_period=100000
_initial_pids=64
_updated_pids=32

__cleanup() {
  __remove_oci_container "$_oci_runtime_root" "$_resource_update_id"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__configure_initial_resources() {
  local _config_tmp

  _config_tmp="$(mktemp)"
  sudo jq \
    --argjson _memory "$_initial_memory_bytes" \
    --argjson _quota "$_initial_cpu_quota" \
    --argjson _period "$_cpu_period" \
    --argjson _pids "$_initial_pids" \
    '.linux.resources.memory.limit = $_memory
      | .linux.resources.memory.swap = $_memory
      | .linux.resources.cpu.quota = $_quota
      | .linux.resources.cpu.period = $_period
      | .linux.resources.pids.limit = $_pids' \
    "${_bundle}/config.json" >"$_config_tmp"
  sudo install -m 0600 "$_config_tmp" "${_bundle}/config.json"
  rm -f "$_config_tmp"
}

__assert_cgroup_value() {
  local _cgroup="$1"
  local _file="$2"
  local _expected="$3"
  local _actual

  _actual="$(sudo cat "${_cgroup}/${_file}")"
  printf 'resource-update-%s=%s\n' "$_file" "$_actual"
  if [[ "$_actual" != "$_expected" ]]; then
    echo "unexpected ${_file}: got ${_actual}, want ${_expected}" >&2
    return 1
  fi
}

__container_memtotal_kib() {
  sudo nscell --root "$_oci_runtime_root" exec "$_resource_update_id" \
    /bin/sh -c "awk '\$1 == \"MemTotal:\" { print \$2; exit }' /proc/meminfo"
}

__assert_container_memtotal() {
  local _expected_bytes="$1"
  local _expected_kib=$((_expected_bytes / 1024))
  local _actual_kib

  _actual_kib="$(__container_memtotal_kib)"
  printf 'resource-update-memtotal-kib=%s\n' "$_actual_kib"
  if [[ "$_actual_kib" != "$_expected_kib" ]]; then
    echo "unexpected container MemTotal: got ${_actual_kib}, want ${_expected_kib}" >&2
    return 1
  fi
}

__main() {
  local _pid _process_cgroup _container_cgroup _stats_output

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
  __configure_initial_resources

  __log "validating initial OCI resource constraints"
  sudo nscell --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    --pid-file "${_bundle}/init.pid" \
    "$_resource_update_id"
  sudo nscell --root "$_oci_runtime_root" start "$_resource_update_id"
  _pid="$(sudo cat "${_bundle}/init.pid")"
  _process_cgroup="$(__host_cgroup_path "$_pid")"
  _container_cgroup="$(__find_ancestor_cgroup_with_value \
    "$_process_cgroup" memory.max "$_initial_memory_bytes")"
  printf 'resource-update-cgroup=%s\n' "$_container_cgroup"
  __assert_cgroup_value "$_container_cgroup" memory.max "$_initial_memory_bytes"
  __assert_cgroup_value "$_container_cgroup" memory.swap.max 0
  __assert_cgroup_value "$_container_cgroup" cpu.max "${_initial_cpu_quota} ${_cpu_period}"
  __assert_cgroup_value "$_container_cgroup" pids.max "$_initial_pids"
  __assert_container_memtotal "$_initial_memory_bytes"

  __log "updating resources on the running OCI container"
  sudo nscell --root "$_oci_runtime_root" update \
    --memory "$_updated_memory_bytes" \
    --memory-swap "$_updated_memory_bytes" \
    --cpu-quota "$_updated_cpu_quota" \
    --cpu-period "$_cpu_period" \
    --pids-limit "$_updated_pids" \
    "$_resource_update_id"

  __assert_cgroup_value "$_container_cgroup" memory.max "$_updated_memory_bytes"
  __assert_cgroup_value "$_container_cgroup" memory.swap.max 0
  __assert_cgroup_value "$_container_cgroup" cpu.max "${_updated_cpu_quota} ${_cpu_period}"
  __assert_cgroup_value "$_container_cgroup" pids.max "$_updated_pids"
  __assert_container_memtotal "$_updated_memory_bytes"

  _stats_output="$(sudo nscell --root "$_oci_runtime_root" events --stats \
    "$_resource_update_id")"
  printf 'resource-update-stats=%s\n' "$_stats_output"
  jq -e \
    --arg _id "$_resource_update_id" \
    --argjson _memory "$_updated_memory_bytes" \
    '.type == "stats"
      and .id == $_id
      and .data.memory.usage.limit == $_memory
      and .data.pids.current >= 1' \
    <<<"$_stats_output" >/dev/null

  trap - EXIT
  __cleanup
  echo "resource-update-validation-ok"
}

__main "$@"
