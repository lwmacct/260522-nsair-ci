#!/usr/bin/env bash

__assert_nsair_ready() {
	__log "checking nsair services"
	systemctl is-active --quiet nsair-daemon.service
	grep -q "Ready ..." /var/log/nsair-daemon.log
	! grep -q "ID-mapped mounts are required" /var/log/nsair-daemon.log
	! grep -q "overlayfs on ID-mapped mounts is required" /var/log/nsair-daemon.log
	docker info --format '{{json .Runtimes}}' | jq -e 'has("nsair-runtime")' >/dev/null
}
