#!/usr/bin/env bash
# shellcheck disable=all

set -euo pipefail

_script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_repo_root="$(cd "${_script_dir}/.." && pwd)"
_runtime_test_dir="${_repo_root}/ci/runtime/test"

_nsair_image="${NSAIR_IMAGE:-ghcr.io/lwmacct/260522-nsair:latest}"
_test_root="${NSAIR_CI_TEST_ROOT:-/tmp/nsair}"
_image_cache_dir="${NSAIR_CI_IMAGE_CACHE_DIR:-${_test_root}/images}"
_gate_mode="${NSAIR_GATE_MODE:-ci}"
_target_platform="${NSAIR_IMAGE_PLATFORM:-linux/amd64}"
_release_root="${NSAIR_RELEASE_ROOT:-/opt/nsair/releases}"
_current_link="${NSAIR_CURRENT_LINK:-/opt/nsair/current}"
_run_id="${NSAIR_WORKLOAD_RUN_ID:-${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}}"
_resource_id="$(printf '%s' "$_run_id" | tr -c '[:alnum:]_.-' '-')"
_resource_id="${_resource_id:0:32}"

__log() {
  printf '\n==> %s\n' "$*" >&2
}

__require_cmd() {
  local _cmd="$1"
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "missing required command: $_cmd" >&2
    exit 1
  fi
}

__install_dependencies() {
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    jq \
    libseccomp2 \
    util-linux
}

__show_host_capabilities() {
  set -x
  uname -a
  cat /sys/kernel/security/lsm || true
  findmnt /sys/fs/bpf || true
  docker version
  docker info
  oras version
}

__setup_runtime_host() {
  __require_cmd sudo
  __require_cmd docker
  __require_cmd systemctl
  __require_cmd jq
  __require_cmd oras

  __init_ci_dirs
  __install_nsair_binaries
  __install_nsair_systemd_unit
  __configure_docker_runtime
  __restart_nsair_services
  echo "ci-setup-ok"
}

__init_ci_dirs() {
  sudo install -d -m 0755 "$_test_root" "$_image_cache_dir"
  sudo chown -R "$(id -u):$(id -g)" "$_test_root"
}

__image_repo() {
  local _ref="$1"
  local _repo _last

  _repo="${_ref%%@*}"
  _last="${_repo##*/}"
  if [[ "$_last" == *:* ]]; then
    _repo="${_repo%:*}"
  fi
  printf '%s' "$_repo"
}

__extract_nsair_binaries_from_image() {
  local _dest="$1"
  local _work_dir _manifest _repo _digest _layer _i

  _work_dir="$(mktemp -d "${_test_root}/oras-image.XXXXXX")"
  _manifest="${_work_dir}/manifest.json"
  _repo="$(__image_repo "$_nsair_image")"

  __log "fetching ${_target_platform} manifest from ${_nsair_image}"
  oras manifest fetch --platform "$_target_platform" --output "$_manifest" "$_nsair_image"

  mkdir -p "${_work_dir}/rootfs" "${_work_dir}/layers"
  _i=0
  while IFS= read -r _digest; do
    [[ -n "$_digest" ]] || continue
    _i=$((_i + 1))
    _layer="${_work_dir}/layers/${_i}.tar"
    __log "fetching layer ${_i}: ${_digest}"
    oras blob fetch --output "$_layer" "${_repo}@${_digest}"
    tar -xf "$_layer" -C "${_work_dir}/rootfs"
  done < <(jq -r '.layers[].digest' "$_manifest")

  install -d -m 0755 "$_dest"
  install -m 0755 "${_work_dir}/rootfs/usr/local/bin/nsair-daemon" "${_dest}/nsair-daemon"
  install -m 0755 "${_work_dir}/rootfs/usr/local/bin/nsair-runtime" "${_dest}/nsair-runtime"
  rm -rf "$_work_dir"
}

__install_nsair_binaries() {
  local _release _artifact_bin_dir
  _release="${_release_root}/$(date +%Y%m%d%H%M%S)-ci"
  _artifact_bin_dir="${_test_root}/nsair-bin"

  __log "removing previous validation containers before installing binaries"
  docker ps -a --format '{{.Names}}' |
    awk '/^nsair-(docker-in-docker|kubernetes-k3s|systemd-pid1|procfs-memory|procfs-cpu|seccomp-notify-concurrency|container-security-policy)/ { print }' |
    xargs -r docker rm -f >/dev/null 2>&1 || true
  docker network ls --format '{{.Name}}' |
    awk '/^nsair-docker-in-docker/ { print }' |
    xargs -r docker network rm >/dev/null 2>&1 || true

  rm -rf "$_artifact_bin_dir"
  __extract_nsair_binaries_from_image "$_artifact_bin_dir"
  "${_artifact_bin_dir}/nsair-daemon" version
  "${_artifact_bin_dir}/nsair-runtime" version

  __log "installing nsair binaries to ${_release}"
  sudo install -d -m 0755 "${_release}/bin"
  sudo install -m 0755 "${_artifact_bin_dir}/nsair-runtime" "${_release}/bin/nsair-runtime"
  sudo install -m 0755 "${_artifact_bin_dir}/nsair-daemon" "${_release}/bin/nsair-daemon"
  sudo ln -sfn "$_release" "$_current_link"
  sudo ln -sfn "${_current_link}/bin/nsair-runtime" /usr/bin/nsair-runtime
  sudo ln -sfn "${_current_link}/bin/nsair-daemon" /usr/bin/nsair-daemon
  sudo rm -f /usr/bin/nsair-runc /usr/bin/nsaird /usr/bin/nsair-policy
}

__install_nsair_systemd_unit() {
  case "$_gate_mode" in
  strict | ci) ;;
  *)
    echo "unsupported NSAIR_GATE_MODE: $_gate_mode" >&2
    exit 2
    ;;
  esac

  __log "installing nsair-daemon systemd unit"
  sudo systemctl disable nsaird.service >/dev/null 2>&1 || true
  sudo rm -f /etc/systemd/system/nsaird.service
  sudo tee /etc/systemd/system/nsair-daemon.service >/dev/null <<EOF
[Unit]
Description=nsair-daemon (Nsair unified daemon)
Before=docker.service containerd.service

[Service]
Type=notify
Environment=NSAIR_GATE_MODE=${_gate_mode}
ExecStart=/usr/bin/nsair-daemon --log /var/log/nsair-daemon.log --metrics-listen 127.0.0.1:9618
TimeoutStartSec=45
TimeoutStopSec=90
StartLimitInterval=0
NotifyAccess=main
OOMScoreAdjust=-500
LimitNOFILE=infinity
LimitNPROC=infinity

[Install]
WantedBy=multi-user.target
EOF
  sudo systemctl daemon-reload
  sudo systemctl enable nsair-daemon.service >/dev/null
}

__configure_docker_runtime() {
  local _daemon_config="/etc/docker/daemon.json"
  local _tmp_config

  __log "configuring docker nsair-runtime"
  sudo install -d -m 0755 /etc/docker
  _tmp_config="$(mktemp)"
  if sudo test -s "$_daemon_config"; then
    sudo jq '
			if type != "object" then
				error("docker daemon config must be a JSON object")
			else
				.runtimes = ((.runtimes // {})
					| del(."mosbox-runc", ."mosbox-runtime")
					| .["nsair-runtime"] = {
						"path": "/usr/bin/nsair-runtime",
						"runtimeArgs": []
					})
			end
		' "$_daemon_config" >"$_tmp_config"
  else
    jq -n '{
			"runtimes": {
				"nsair-runtime": {
					"path": "/usr/bin/nsair-runtime",
					"runtimeArgs": []
				}
			}
		}' >"$_tmp_config"
  fi
  sudo install -m 0644 "$_tmp_config" "$_daemon_config"
  rm -f "$_tmp_config"
}

__restart_nsair_services() {
  __log "restarting nsair-daemon and docker"
  docker ps -a --format '{{.Names}}' |
    awk '/^nsair-(docker-in-docker|kubernetes-k3s|systemd-pid1|procfs-memory|procfs-cpu|seccomp-notify-concurrency|container-security-policy)/ { print }' |
    xargs -r docker rm -f >/dev/null 2>&1 || true
  sudo truncate -s 0 /var/log/nsair-daemon.log 2>/dev/null || sudo install -m 0600 /dev/null /var/log/nsair-daemon.log
  sudo systemctl reset-failed docker.service nsair-daemon.service nsaird.service || true
  sudo systemctl stop nsair-daemon.service nsaird.service || true
  while read -r _mp; do
    [[ -n "$_mp" ]] || continue
    sudo umount -l "$_mp" || true
  done < <(awk '$0 ~ / - fuse nsairfs / && $5 ~ /^\/var\/lib\/nsairfs\// {print $5}' /proc/self/mountinfo)
  sudo rm -f /run/nsair/daemon.sock /run/nsair/nsaird.sock /run/nsair/seccomp-notify.sock /run/nsair/daemon.pid /run/nsair/nsaird.pid
  sudo rm -rf /run/nsair/sessions
  if sudo test -d /var/lib/nsairfs; then
    sudo find /var/lib/nsairfs -mindepth 1 -maxdepth 1 -xdev -exec rm -rf -- {} + 2>/dev/null || true
  fi
  sudo systemctl restart nsair-daemon.service
  sudo systemctl is-active --quiet nsair-daemon.service
  sudo systemctl restart docker
  __assert_nsair_ready
}

__verify_gate() {
  sudo systemctl is-active --quiet nsair-daemon.service
  sudo systemctl cat nsair-daemon.service
  sudo nsair-daemon gate status
  sudo nsair-daemon gate status | jq -e '.mode == "ci" and .enforce == false'
}

__assert_nsair_ready() {
  __log "checking nsair services"
  sudo systemctl is-active --quiet nsair-daemon.service
  sudo grep -q "Ready ..." /var/log/nsair-daemon.log
  ! sudo grep -q "ID-mapped mounts are required" /var/log/nsair-daemon.log
  ! sudo grep -q "overlayfs on ID-mapped mounts is required" /var/log/nsair-daemon.log
  docker info --format '{{json .Runtimes}}' | jq -e 'has("nsair-runtime")' >/dev/null
}

__run_workload() {
  __require_cmd docker
  __require_cmd jq
  __require_cmd flock
  local _workload="$1"

  if [[ -z "$_workload" || "$_workload" == "all" ]]; then
    echo "run-workload requires one concrete workload name" >&2
    exit 2
  fi

  __assert_nsair_ready
  export NSAIR_CI_TEST_ROOT="$_test_root"
  export NSAIR_CI_IMAGE_CACHE_DIR="$_image_cache_dir"
  export NSAIR_WORKLOAD_RUN_ID="$_resource_id"

  bash "${_runtime_test_dir}/run.sh" run "$_workload"
}

__run_workloads() {
  local -a _workloads=("$@")

  if ((${#_workloads[@]} == 0)); then
    read -r -a _workloads <<<"${NSAIR_CI_WORKLOADS:-procfs-cpu}"
  fi
  if ((${#_workloads[@]} == 0)); then
    _workloads=(procfs-cpu)
  fi
  for _workload in "${_workloads[@]}"; do
    __run_workload "$_workload"
  done
}

__collect_logs() {
  local _log_dir="${_test_root}/runs/${GITHUB_RUN_ID:-local}-${GITHUB_RUN_ATTEMPT:-1}/logs"
  sudo install -d -m 0755 "$_log_dir"
  {
    uname -a || true
    cat /sys/kernel/security/lsm || true
    findmnt /sys/fs/bpf || true
    docker info || true
    docker ps -a || true
    docker images || true
    for _container in $(docker ps -a --format '{{.Names}}' | awk '/^nsair-/ { print }'); do
      docker logs "$_container" || true
    done
    sudo systemctl --no-pager --full status docker.service nsair-daemon.service || true
    sudo systemctl cat nsair-daemon.service || true
    sudo nsair-daemon gate status || true
    sudo journalctl --no-pager -u docker.service -u nsair-daemon.service || true
  } 2>&1 | sudo tee "${_log_dir}/host-diagnostics.log" >/dev/null
  if sudo test -f /var/log/nsair-daemon.log; then
    sudo cp /var/log/nsair-daemon.log "${_log_dir}/nsair-daemon.log"
    sudo chmod 0644 "${_log_dir}/nsair-daemon.log"
  fi
}

__usage() {
  cat <<'EOF'
usage: scripts/nsair-ci.sh <command>

commands:
  install-dependencies
  show-host-capabilities
  setup-runtime-host
  verify-gate
  run-workload <workload>
  run-workloads [workload...]
  collect-logs
EOF
}

case "${1:-}" in
install-dependencies)
  __install_dependencies
  ;;
show-host-capabilities)
  __show_host_capabilities
  ;;
setup-runtime-host)
  __setup_runtime_host
  ;;
verify-gate)
  __verify_gate
  ;;
run-workload)
  shift
  __run_workload "${1:-}"
  ;;
run-workloads)
  shift
  __run_workloads "$@"
  ;;
collect-logs)
  __collect_logs
  ;;
-h | --help | help)
  __usage
  ;;
*)
  __usage >&2
  exit 2
  ;;
esac
