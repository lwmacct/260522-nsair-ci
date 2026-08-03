#!/usr/bin/env bash

__assert_nscell_ready() {
	__log "checking nscell services"
	systemctl is-active --quiet nscell-daemon.service
	grep -q "Ready ..." "$_daemon_log"
	! grep -q "ID-mapped mounts are required" "$_daemon_log"
	! grep -q "overlayfs on ID-mapped mounts is required" "$_daemon_log"
	docker info --format '{{json .Runtimes}}' | jq -e 'has("nscell")' >/dev/null
}
