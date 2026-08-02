#!/usr/bin/env bash

__assert_nsair_ready() {
	__log "checking nsair services"
	systemctl is-active --quiet nsair-supervisor.service
	systemctl is-active --quiet nsair-daemon.service
	grep -q "Ready ..." "$_daemon_log"
	! grep -q "ID-mapped mounts are required" "$_daemon_log"
	! grep -q "overlayfs on ID-mapped mounts is required" "$_daemon_log"
	docker info --format '{{json .Runtimes}}' | jq -e 'has("nsair-runtime")' >/dev/null
}
