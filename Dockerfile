# syntax=docker/dockerfile:1
ARG TILESERVER_VERSION=v5.7.0

FROM maptiler/tileserver-gl:${TILESERVER_VERSION} AS tileserver

# ---------------------------------------------------------------------------
# Stage 1: styles, sprites en fonts ophalen (op vaste commits) en omzetten
# ---------------------------------------------------------------------------
FROM python:3.13-alpine AS assets

# Upstream-styles, vastgepind zodat elke build hetzelfde oplevert
ARG POSITRON_COMMIT=bed9a6349dfb431bd8a6646101d0977b59c591dd
ARG POSITRON_PAGES=98f91afa38671a885947d721075bdc88392c1b78
ARG BRIGHT_COMMIT=563b249f7ae71528b1f1e327cb9c019d0dda4c50
ARG BRIGHT_PAGES=286b174adbd6e8693887841d6cfdf7445cd5f8c0
ARG LIBERTY_COMMIT=40a0d19861c9d26805dee3daab5cb366badb6678
ARG FONTS_URL=https://github.com/openmaptiles/fonts/releases/download/v2.0/v2.0.zip
ARG FONTS_SHA256=3a7a6c2dcd940a840aa6ffac8f39758252a667a0b329945b071fb44bf00e7f47

RUN apk add --no-cache curl

WORKDIR /src
RUN set -eu; \
    raw=https://raw.githubusercontent.com; \
    get() { curl -fsSL --retry 5 --retry-delay 5 -o "$2" "$1"; }; \
    for s in positron:openmaptiles/positron-gl-style:${POSITRON_COMMIT}:${POSITRON_PAGES} \
             osm-bright:openmaptiles/osm-bright-gl-style:${BRIGHT_COMMIT}:${BRIGHT_PAGES}; do \
      id=${s%%:*}; rest=${s#*:}; repo=${rest%%:*}; rest=${rest#*:}; commit=${rest%%:*}; pages=${rest#*:}; \
      mkdir -p $id; \
      get $raw/$repo/$commit/style.json   $id/style.json; \
      get $raw/$repo/$commit/LICENSE.md   $id/LICENSE.md; \
      for f in sprite.json sprite.png sprite@2x.json sprite@2x.png; do \
        get $raw/$repo/$pages/$f $id/$f; \
      done; \
    done; \
    mkdir -p osm-liberty; \
    get $raw/maputnik/osm-liberty/${LIBERTY_COMMIT}/style.json osm-liberty/style.json; \
    get $raw/maputnik/osm-liberty/${LIBERTY_COMMIT}/LICENSE.md osm-liberty/LICENSE.md; \
    for f in osm-liberty.json osm-liberty.png osm-liberty@2x.json osm-liberty@2x.png; do \
      get $raw/maputnik/osm-liberty/${LIBERTY_COMMIT}/sprites/$f osm-liberty/$f; \
    done; \
    get "${FONTS_URL}" fonts.zip; \
    echo "${FONTS_SHA256}  fonts.zip" | sha256sum -c -

COPY docker/build_styles.py /build_styles.py
RUN python3 /build_styles.py /src /config

# ---------------------------------------------------------------------------
# Stage 2: tileserver-gl met de gegenereerde config
# ---------------------------------------------------------------------------
FROM tileserver

LABEL org.opencontainers.image.source="https://github.com/ColombiaTransit/tileserver-docker" \
      org.opencontainers.image.description="TileServer GL met Colombia vector- en terrain-tiles: Positron, OSM Bright en OSM Liberty (2D en 3D)" \
      org.opencontainers.image.licenses="BSD-3-Clause"

COPY --from=assets /config /config
COPY --chmod=755 docker/start.sh /usr/local/bin/start-tileserver
COPY docker/fetch-tiles.mjs /usr/local/lib/tileserver-docker/fetch-tiles.mjs

# De .mbtiles-bestanden staan op een volume op /data en worden bij het
# opstarten opgehaald of bijgewerkt (fetch-tiles.mjs):
#   colombia.mbtiles          ~430 MB
#   colombia-terrain.mbtiles  ~4,2 GiB
# De eerste start duurt daardoor een paar minuten; de healthcheck krijgt
# daarom ruim de tijd.
#
# PUBLIC_URL    zet --public_url, bijv. https://tileserver.colombiatransit.co/
# TILES_UPDATE  false = niets ophalen, alleen bestaande bestanden gebruiken
ENV PUBLIC_URL="" \
    TILES_UPDATE="true"
HEALTHCHECK --start-period=30m --interval=30s --timeout=10s --retries=3 \
    CMD node /usr/src/app/src/healthcheck.js
ENTRYPOINT ["/usr/local/bin/start-tileserver"]
