#!/usr/bin/env bash

set -euo pipefail

_state_root="/run/nscell-ci-storage-crash-boundaries"
_real_rsync="/usr/bin/rsync"

__main() {
  local _mode _target_id _src _dest _daemon_pid
  local -a _args=("$@")
  local -a _options=()

  if ((${#_args[@]} < 2)) || [[ -e "${_state_root}/triggered" ]]; then
    exec "$_real_rsync" "$@"
  fi
  if ! IFS=: read -r _mode _target_id <"${_state_root}/mode"; then
    exec "$_real_rsync" "$@"
  fi

  _src="${_args[${#_args[@]}-2]}"
  _dest="${_args[${#_args[@]}-1]}"
  case "$_mode" in
    sync-in)
      [[ "$_dest" == "/var/lib/nscell/work/docker/${_target_id}" ]] ||
        exec "$_real_rsync" "$@"
      ;;
    sync-out)
      [[ "$_src" == "/var/lib/nscell/work/docker/${_target_id}/" ]] ||
        exec "$_real_rsync" "$@"
      ;;
    *)
      exec "$_real_rsync" "$@"
      ;;
  esac

  _options=("${_args[@]:0:${#_args[@]}-2}")
  "$_real_rsync" \
    "${_options[@]}" \
    --include=/partial.txt \
    --exclude='*' \
    "$_src" \
    "$_dest"

  _daemon_pid="$PPID"
  printf '%s\n' "$_daemon_pid" >"${_state_root}/daemon.pid"
  printf '%s:%s\n' "$_mode" "$_target_id" >"${_state_root}/triggered"
  sync -f "$_state_root"
  while [[ -d "/proc/${_daemon_pid}" ]]; do
    sleep 0.1
  done
  exit 137
}

__main "$@"
