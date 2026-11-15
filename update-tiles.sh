#!/usr/bin/env bash
# Haalt de nieuwste colombia.mbtiles uit de GitHub-release en herstart
# tileserver-gl alleen als er echt een nieuwe versie is.
# Gebruik: ./update-tiles.sh          (vanuit deze map, of via cron)
set -euo pipefail

REPO="ColombiaTransit/colombia-mbtiles"
TAG="planetiler-latest"
FILE="colombia.mbtiles"
CONTAINER="tileserver-colombia"

DIR="$(cd "$(dirname "$0")" && pwd)/data"
BASE="https://github.com/${REPO}/releases/download/${TAG}"

mkdir -p "$DIR"
cd "$DIR"

# 1. Checksum van de release ophalen en vergelijken met wat we hebben
remote_sum=$(curl -fsSL --retry 3 "${BASE}/${FILE}.sha256" | awk '{print $1}')
local_sum=$(cat "${FILE}.sha256" 2>/dev/null || true)

if [ -s "$FILE" ] && [ "$remote_sum" = "$local_sum" ]; then
  echo "$(date -Is) Geen update: ${FILE} is al de nieuwste (${remote_sum:0:12})"
  exit 0
fi

# 2. Downloaden naar tijdelijk bestand en verifiëren
echo "$(date -Is) Nieuwe versie gevonden, downloaden..."
curl -fL --retry 5 --retry-delay 15 -o "${FILE}.tmp" "${BASE}/${FILE}"

got_sum=$(sha256sum "${FILE}.tmp" | awk '{print $1}')
if [ "$got_sum" != "$remote_sum" ]; then
  echo "$(date -Is) FOUT: checksum klopt niet, update afgebroken" >&2
  rm -f "${FILE}.tmp"
  exit 1
fi

# 3. Atomair vervangen en tileserver herstarten
mv -f "${FILE}.tmp" "$FILE"
echo "$remote_sum" > "${FILE}.sha256"

if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  docker restart "$CONTAINER" >/dev/null
  echo "$(date -Is) ${CONTAINER} herstart met nieuwe tiles (${remote_sum:0:12})"
else
  echo "$(date -Is) Tiles bijgewerkt; ${CONTAINER} draait niet, start hem met 'docker compose up -d'"
fi
