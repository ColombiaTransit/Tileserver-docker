#!/bin/bash
# Start tileserver-gl met de ingebakken config. Extra argumenten uit
# `command:` in compose worden doorgegeven.
set -e
args=(--config /config/config.json)
if [ -n "${PUBLIC_URL}" ]; then
  args+=(--public_url "${PUBLIC_URL}")
fi
exec /usr/src/app/docker-entrypoint.sh "${args[@]}" "$@"
