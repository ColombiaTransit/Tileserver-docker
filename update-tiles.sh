#!/usr/bin/env bash
# Haalt de nieuwste tiles op en herstart tileserver-gl alleen als er
# iets veranderd is.
#   - colombia.mbtiles          vector tiles (ColombiaTransit/colombia-mbtiles)
#   - colombia-terrain.mbtiles  Terrain-RGB hoogtes (ColombiaTransit/colombia-height)
# Gebruik: ./update-tiles.sh   (vanuit deze map, of via cron)
set -euo pipefail

CONTAINER="tileserver-colombia"
DIR="$(cd "$(dirname "$0")" && pwd)/data"
mkdir -p "$DIR"
cd "$DIR"

changed=0
log() { echo "$(date -Is) $*"; }

# --- Vector tiles ---------------------------------------------------------
update_vector() {
  local file="colombia.mbtiles"
  local base="https://github.com/ColombiaTransit/colombia-mbtiles/releases/download/planetiler-latest"
  local remote local_sum got

  remote=$(curl -fsSL --retry 3 "${base}/${file}.sha256" | awk '{print $1}') || return 1
  [ -n "$remote" ] || { log "Vector: geen checksum gevonden" >&2; return 1; }
  local_sum=$(cat "${file}.sha256" 2>/dev/null || true)

  if [ -s "$file" ] && [ "$remote" = "$local_sum" ]; then
    log "Vector: al de nieuwste (${remote:0:12})"
    return
  fi

  log "Vector: nieuwe versie, downloaden..."
  curl -fL --retry 5 --retry-delay 15 -o "${file}.tmp" "${base}/${file}" || { rm -f "${file}.tmp"; return 1; }
  got=$(sha256sum "${file}.tmp" | awk '{print $1}')
  if [ "$got" != "$remote" ]; then
    rm -f "${file}.tmp"
    log "Vector: FOUT, checksum klopt niet; oude versie blijft staan" >&2
    return 1
  fi
  mv -f "${file}.tmp" "$file"
  echo "$remote" > "${file}.sha256"
  log "Vector: bijgewerkt (${remote:0:12})"
  changed=1
}

# --- Terrain-RGB (hoogtes) --------------------------------------------------
# Bij uitvoering binnen '||' staat set -e uit; daarom expliciete 'return 1'.
# Het bestand is ~4,2 GiB en staat in delen in de release. De installer van
# colombia-height downloadt, verifieert en installeert het atomair; hij heeft
# alleen python3 nodig. Tijdens een update is ~2x de bestandsgrootte vrij nodig.
update_terrain() {
  local file="colombia-terrain.mbtiles"
  local repo="https://github.com/ColombiaTransit/colombia-height"
  local remote local_sum

  remote=$(curl -fsSL --retry 3 "${repo}/releases/latest/download/colombia-terrain.manifest.json" \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["merged_mbtiles_sha256"])') || return 1
  [ -n "$remote" ] || { log "Terrain: geen checksum in manifest" >&2; return 1; }
  local_sum=$(cat "${file}.sha256" 2>/dev/null || true)

  if [ -s "$file" ] && [ "$remote" = "$local_sum" ]; then
    log "Terrain: al de nieuwste (${remote:0:12})"
    return
  fi

  log "Terrain: nieuwe versie, installeren..."
  curl -fsSL --retry 3 \
    https://raw.githubusercontent.com/ColombiaTransit/colombia-height/main/scripts/install_terrain_release.py \
    | python3 - --tag latest --output "$DIR/$file" --replace || return 1
  echo "$remote" > "${file}.sha256"
  log "Terrain: bijgewerkt (${remote:0:12})"
  changed=1
}

status=0
update_vector  || status=1
update_terrain || status=1

if [ "$changed" -eq 1 ]; then
  if docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
    docker restart "$CONTAINER" >/dev/null
    log "${CONTAINER} herstart"
  else
    log "Tiles bijgewerkt; ${CONTAINER} draait niet, start hem met 'docker compose up -d'"
  fi
fi

exit $status
