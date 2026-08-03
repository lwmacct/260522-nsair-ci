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

_bundle="${_volume_root}/daemon-dial-retry/bundle"
_create_log="${_log_root}/daemon-dial-retry-create.log"
_export_name="nsair-oci-export-${_workload_resource_id:-daemon-dial-retry}"

__restore_daemon() {
  sudo systemctl start nsair-daemon.service >/dev/null 2>&1 || true
  __remove_oci_container "$_oci_runtime_root" "$_daemon_dial_retry_id"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  __remove_oci_bundle "$_bundle"
}

__main() {
  local _create_pid _started_ms _finished_ms _elapsed_ms

  if [[ "${1:-}" == "cleanup" ]]; then
    __restore_daemon
    return
  fi

  __require_cmd docker
  __require_cmd jq
  __require_cmd systemctl
  __assert_nsair_ready
  __init_ci_dirs
  trap __restore_daemon EXIT

  __remove_oci_container "$_oci_runtime_root" "$_daemon_dial_retry_id"
  __prepare_oci_bundle \
    "$_oci_base_image" \
    "$_bundle" \
    '["/bin/true"]' \
    "$_export_name"

  __log "stopping an idle daemon before issuing an OCI create request"
  sudo systemctl stop nsair-daemon.service
  if systemctl is-active --quiet nsair-daemon.service; then
    echo "daemon remained active after systemctl stop" >&2
    exit 1
  fi
  _started_ms="$(date +%s%3N)"
  # shellcheck disable=SC2024 # The workload log directory is owned by the caller.
  sudo nsair --root "$_oci_runtime_root" create \
    --bundle "$_bundle" \
    "$_daemon_dial_retry_id" >"$_create_log" 2>&1 &
  _create_pid=$!
  sleep 1
  if ! kill -0 "$_create_pid" >/dev/null 2>&1; then
    wait "$_create_pid" || true
    echo "OCI create did not wait for the daemon retry window" >&2
    cat "$_create_log" >&2
    exit 1
  fi

  __log "restoring daemon inside the runtime client's retry window"
  sudo systemctl start nsair-daemon.service
  if ! wait "$_create_pid"; then
    echo "OCI create failed after daemon recovery" >&2
    cat "$_create_log" >&2
    exit 1
  fi
  _finished_ms="$(date +%s%3N)"
  _elapsed_ms=$((_finished_ms - _started_ms))
  if ((_elapsed_ms < 900 || _elapsed_ms >= 5000)); then
    echo "OCI create retry duration ${_elapsed_ms}ms is outside the expected window" >&2
    exit 1
  fi

  sudo nsair --root "$_oci_runtime_root" state "$_daemon_dial_retry_id" |
    jq -e '.status == "created" and .pid > 0' >/dev/null
  sudo nsair --root "$_oci_runtime_root" delete --force "$_daemon_dial_retry_id"
  __assert_nsair_ready

  trap - EXIT
  __restore_daemon
  echo "daemon-dial-retry-validation-ok elapsed=${_elapsed_ms}ms"
}

__main "$@"
