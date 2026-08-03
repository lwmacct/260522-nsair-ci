#!/usr/bin/env bash

__prepare_oci_bundle() {
  local _image="$1"
  local _bundle="$2"
  local _process_args_json="$3"
  local _export_name="$4"
  local _container _config_tmp

  __ensure_host_image "$_image"
  docker rm -f "$_export_name" >/dev/null 2>&1 || true
  sudo rm -rf "$_bundle"
  install -d -m 0755 "$_bundle"
  sudo install -d -m 0755 "${_bundle}/rootfs"

  _container="$(docker create --name "$_export_name" "$_image")"
  if ! docker export "$_container" | sudo tar --numeric-owner -xpf - -C "${_bundle}/rootfs"; then
    docker rm -f "$_container" >/dev/null 2>&1 || true
    return 1
  fi
  docker rm "$_container" >/dev/null
  sudo chown -R 0:0 "${_bundle}/rootfs"

  sudo nsair spec --bundle "$_bundle"
  _config_tmp="$(mktemp)"
  # shellcheck disable=SC2024 # The temporary output file is owned by the caller.
  sudo jq \
    --argjson _args "$_process_args_json" \
    '.process.args = $_args
      | .process.terminal = false
      | .annotations["io.backend.security.profile"] = "default"' \
    "${_bundle}/config.json" >"$_config_tmp"
  sudo install -m 0600 "$_config_tmp" "${_bundle}/config.json"
  rm -f "$_config_tmp"
}

__remove_oci_container() {
  local _root="$1"
  local _id="$2"

  sudo nsair --root "$_root" delete --force "$_id" >/dev/null 2>&1 || true
}

__remove_oci_bundle() {
  local _bundle="$1"

  sudo rm -rf "$_bundle"
}
