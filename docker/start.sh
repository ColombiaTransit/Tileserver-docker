#!/bin/bash
# 1. Tiles ophalen of bijwerken (zie fetch-tiles.mjs; uit met TILES_UPDATE=false)
# 2. tileserver-gl starten met de ingebakken config. Extra argumenten uit
#    `command:` in compose worden doorgegeven.
set -e
node /usr/local/lib/tileserver-docker/fetch-tiles.mjs

args=(--config /config/config.json)
if [ -n "${PUBLIC_URL}" ]; then
  args+=(--public_url "${PUBLIC_URL}")
fi
exec /usr/src/app/docker-entrypoint.sh "${args[@]}" "$@"
