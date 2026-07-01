#!/usr/bin/env bash

__safe_resource_id() {
  local _value="$1"
  printf '%s' "$_value" | tr -c '[:alnum:]_.-' '-'
}

__image_tag() {
  local _repo="$1"
  local _default_tag="$2"

  if [[ -n "$_workload_resource_id" ]]; then
    printf '%s:%s\n' "$_repo" "$_workload_resource_id"
  else
    printf '%s:%s\n' "$_repo" "$_default_tag"
  fi
}

_test_root="${NSAIR_CI_TEST_ROOT:-/data/nsair}"
_workload_id="${NSAIR_WORKLOAD_ID:-}"
_workload_resource_id=""
_workload_run_root="$_test_root"
if [[ -n "$_workload_id" ]]; then
  _workload_resource_id="$(__safe_resource_id "$_workload_id")"
  _workload_run_root="${_test_root}/runs/${_workload_resource_id}"
fi

_image_cache_dir="${NSAIR_CI_IMAGE_CACHE_DIR:-${_test_root}/images}"
_volume_root="${NSAIR_CI_VOLUME_ROOT:-${_workload_run_root}/volumes}"
_log_root="${NSAIR_CI_LOG_ROOT:-${_workload_run_root}/logs}"

_docker_in_docker_name="${NSAIR_CI_DOCKER_IN_DOCKER_NAME:-nsair-docker-in-docker${_workload_resource_id:+-${_workload_resource_id}}}"
_docker_in_docker_network="${NSAIR_CI_DOCKER_IN_DOCKER_NETWORK:-nsair-docker-in-docker${_workload_resource_id:+-${_workload_resource_id}}}"
_docker_in_docker_base_image="${NSAIR_CI_DOCKER_IN_DOCKER_BASE_IMAGE:-ghcr.io/lwmacct/250210-cr-docker:29.4.0-dind-260408}"
_docker_in_docker_image="${NSAIR_CI_DOCKER_IN_DOCKER_IMAGE:-$(__image_tag nsair-ci/docker-in-docker latest)}"

_container_security_policy_name="${NSAIR_CI_CONTAINER_SECURITY_POLICY_NAME:-nsair-container-security-policy${_workload_resource_id:+-${_workload_resource_id}}}"
_container_security_policy_base_image="${NSAIR_CI_CONTAINER_SECURITY_POLICY_BASE_IMAGE:-docker.io/library/python:3.12-alpine}"
_container_security_policy_image="${NSAIR_CI_CONTAINER_SECURITY_POLICY_IMAGE:-$(__image_tag nsair-ci/container-security-policy latest)}"

_kubernetes_k3s_name="${NSAIR_CI_KUBERNETES_K3S_NAME:-nsair-kubernetes-k3s${_workload_resource_id:+-${_workload_resource_id}}}"
_kubernetes_k3s_base_image="${NSAIR_CI_KUBERNETES_K3S_BASE_IMAGE:-docker.io/rancher/k3s:v1.30.6-k3s1}"
_kubernetes_k3s_image="${NSAIR_CI_KUBERNETES_K3S_IMAGE:-$(__image_tag nsair-ci/kubernetes-k3s latest)}"
_kubernetes_k3s_pause_source_image="${NSAIR_CI_KUBERNETES_K3S_PAUSE_SOURCE_IMAGE:-docker.io/rancher/mirrored-pause:3.6}"
_kubernetes_k3s_pause_image="${NSAIR_CI_KUBERNETES_K3S_PAUSE_IMAGE:-docker.io/rancher/mirrored-pause:3.6}"
_kubernetes_k3s_pod_name="${NSAIR_CI_KUBERNETES_K3S_POD_NAME:-nsair-kubernetes-k3s-nginx${_workload_resource_id:+-${_workload_resource_id}}}"

_systemd_pid1_name="${NSAIR_CI_SYSTEMD_PID1_NAME:-nsair-systemd-pid1${_workload_resource_id:+-${_workload_resource_id}}}"
_systemd_pid1_unit="${NSAIR_CI_SYSTEMD_PID1_UNIT:-nsair-ci-systemd-pid1${_workload_resource_id:+-${_workload_resource_id}}}"
_systemd_pid1_base_image="${NSAIR_CI_SYSTEMD_PID1_BASE_IMAGE:-docker.io/library/ubuntu:24.04}"
_systemd_pid1_image="${NSAIR_CI_SYSTEMD_PID1_IMAGE:-$(__image_tag nsair-ci/systemd-pid1 latest)}"

_procfs_memory_name="${NSAIR_CI_PROCFS_MEMORY_NAME:-nsair-procfs-memory${_workload_resource_id:+-${_workload_resource_id}}}"
_procfs_memory_base_image="${NSAIR_CI_PROCFS_MEMORY_BASE_IMAGE:-docker.io/library/python:3.12-alpine}"
_procfs_memory_image="${NSAIR_CI_PROCFS_MEMORY_IMAGE:-$(__image_tag nsair-ci/procfs-memory latest)}"
_procfs_memory_memory_bytes="${NSAIR_CI_PROCFS_MEMORY_MEMORY_BYTES:-134217728}"
_procfs_memory_swap_bytes="${NSAIR_CI_PROCFS_MEMORY_SWAP_BYTES:-268435456}"
_procfs_memory_overflow_alloc_bytes="${NSAIR_CI_PROCFS_MEMORY_OVERFLOW_ALLOC_BYTES:-268435456}"
_procfs_memory_swap_exercise_alloc_bytes="${NSAIR_CI_PROCFS_MEMORY_SWAP_EXERCISE_ALLOC_BYTES:-201326592}"

_procfs_cpu_name="${NSAIR_CI_PROCFS_CPU_NAME:-nsair-procfs-cpu${_workload_resource_id:+-${_workload_resource_id}}}"
_procfs_cpu_base_image="${NSAIR_CI_PROCFS_CPU_BASE_IMAGE:-docker.io/library/python:3.12-alpine}"
_procfs_cpu_image="${NSAIR_CI_PROCFS_CPU_IMAGE:-$(__image_tag nsair-ci/procfs-cpu latest)}"
_procfs_cpu_quota_cpus="${NSAIR_CI_PROCFS_CPU_QUOTA_CPUS:-0.1}"

_seccomp_notify_concurrency_name="${NSAIR_CI_SECCOMP_NOTIFY_CONCURRENCY_NAME:-nsair-seccomp-notify-concurrency${_workload_resource_id:+-${_workload_resource_id}}}"
_seccomp_notify_concurrency_base_image="${NSAIR_CI_SECCOMP_NOTIFY_CONCURRENCY_BASE_IMAGE:-docker.io/library/python:3.12-alpine}"
_seccomp_notify_concurrency_image="${NSAIR_CI_SECCOMP_NOTIFY_CONCURRENCY_IMAGE:-$(__image_tag nsair-ci/seccomp-notify-concurrency latest)}"
_seccomp_notify_concurrency_processes="${NSAIR_CI_SECCOMP_NOTIFY_CONCURRENCY_PROCESSES:-24}"
_seccomp_notify_concurrency_sysinfo_iterations="${NSAIR_CI_SECCOMP_NOTIFY_CONCURRENCY_SYSINFO_ITERATIONS:-32}"
_seccomp_notify_concurrency_openat2_iterations="${NSAIR_CI_SECCOMP_NOTIFY_CONCURRENCY_OPENAT2_ITERATIONS:-8}"
_seccomp_notify_concurrency_mount_iterations="${NSAIR_CI_SECCOMP_NOTIFY_CONCURRENCY_MOUNT_ITERATIONS:-8}"

_inner_nginx_base_image="${NSAIR_CI_INNER_NGINX_BASE_IMAGE:-docker.io/nginx:latest}"
_inner_nginx_image="${NSAIR_CI_INNER_NGINX_IMAGE:-$(__image_tag nsair-ci/nginx-workload latest)}"

__require_cmd() {
  local _cmd="$1"
  if ! command -v "$_cmd" >/dev/null 2>&1; then
    echo "missing required command: $_cmd" >&2
    exit 1
  fi
}

__log() {
  printf '\n==> %s\n' "$*" >&2
}

__init_ci_dirs() {
  install -d -m 0755 "$_test_root" "$_image_cache_dir" "$_volume_root" "$_log_root"
}
