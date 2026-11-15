# Tileserver-docker

Docker-image met [TileServer GL](https://github.com/maptiler/tileserver-gl) voor Colombia, met styles, sprites en fonts ingebakken. Draait achter Traefik op `https://tileserver.colombiatransit.co/`.

```
ghcr.io/colombiatransit/tileserver-docker:latest
```

Het image wordt automatisch gebouwd en gepubliceerd bij elke push naar `main` die de `Dockerfile` of `docker/` raakt.

## Data

De `.mbtiles` zitten niet in het image; ze komen via een volume op `/data`:

| Data-id | Bestand | Bron |
|---|---|---|
| `v3` | `colombia.mbtiles` – OpenMapTiles vector tiles, ~430 MB | [colombia-mbtiles](https://github.com/ColombiaTransit/colombia-mbtiles), release `planetiler-latest` (elke maandag) |
| `colombia-terrain` | `colombia-terrain.mbtiles` – Terrain-RGB hoogtes, z0–13, ~4,2 GiB | [colombia-height](https://github.com/ColombiaTransit/colombia-height), release `latest` |

Beide bestanden zijn verplicht. `update-tiles.sh` haalt ze op (vereist `python3`; reken op ~10 GiB vrije ruimte tijdens een terrain-update).

## Styles

| Style | 2D | 3D (terrein + hillshade) |
|---|---|---|
| Positron (licht, rustig; goed onder routes en haltes) | `positron` | `positron-3d` |
| OSM Liberty (volledige kaart, met hillshade) | `osm-liberty` | `osm-liberty-3d` |

Style-URL: `https://tileserver.colombiatransit.co/styles/<style>/style.json`

De upstream-styles worden tijdens het bouwen op vaste commits opgehaald en door [`docker/build_styles.py`](docker/build_styles.py) aangepast: bronnen naar de lokale data, eigen sprites en fonts, Colombia als startpositie, en voor de 3D-varianten terrein en hillshade. De natural-earth-relief van OSM Liberty is vervangen door hillshade uit `colombia-terrain`. Styles met hoogtedata worden alleen client-side gerenderd (`serve_rendered: false`).

## Installatie

```bash
git clone https://github.com/ColombiaTransit/tileserver-docker.git
cd tileserver-docker
cp tileserver.yml /etc/traefik/       # map van de Traefik file-provider
./update-tiles.sh                     # eerste download van de tiles
docker compose up -d
```

Tiles wekelijks bijwerken via cron, ruim na de build van maandag 05:25 UTC:

```cron
0 9 * * 1 /pad/naar/tileserver-docker/update-tiles.sh >> /var/log/update-tiles.log 2>&1
```

Een nieuwe versie van het image ophalen:

```bash
docker compose pull && docker compose up -d
```

## Bestanden

| Bestand | Doel |
|---|---|
| `Dockerfile` | Bouwt het image: haalt styles, sprites en fonts op en genereert `/config` |
| `docker/build_styles.py` | Zet de upstream-styles om en schrijft `config.json` |
| `docker/start.sh` | Entrypoint; zet `--public_url` uit `PUBLIC_URL` |
| `docker/make_test_mbtiles.py` | Kleine test-data voor de rooktest in CI |
| `docker-compose.yml` | Container in het `traefik`-netwerk |
| `tileserver.yml` | Traefik-router en middlewares voor `tileserver.colombiatransit.co` |
| `update-tiles.sh` | Werkt de `.mbtiles` bij en herstart de container alleen bij wijzigingen |

## Gebruik in MapLibre

```js
const map = new maplibregl.Map({
  container: 'map',
  style: 'https://tileserver.colombiatransit.co/styles/positron-3d/style.json'
});
```

Terrein toevoegen aan een eigen style:

```js
map.addSource('terrain', {
  type: 'raster-dem',
  url: 'https://tileserver.colombiatransit.co/data/colombia-terrain.json',
  tileSize: 256,
  encoding: 'mapbox'
});
map.setTerrain({ source: 'terrain', exaggeration: 1.3 });
```

Buiten Colombiaans land geeft de terrain-data HTTP 204. De vlakke zee is alleen voor weergave, geen bathymetrie; daarom staat `encoding` bewust niet in de server-config (geen elevation-API).

## Licenties

- Kaartdata © OpenStreetMap-bijdragers, [ODbL-1.0](https://opendatacommons.org/licenses/odbl/)
- Hoogtedata: Copernicus DEM GLO-30, zie [colombia-height](https://github.com/ColombiaTransit/colombia-height/blob/main/release/DATA_LICENSE.md)
- Styles: [Positron](https://github.com/openmaptiles/positron-gl-style) (code BSD-3-Clause, design onder CC-BY; © MapTiler/OpenMapTiles en CARTO), [OSM Liberty](https://github.com/maputnik/osm-liberty) (BSD). De licentie van elke style staat in het image naast de style (`/config/styles/<id>/LICENSE.md`).
- Fonts: [openmaptiles/fonts](https://github.com/openmaptiles/fonts) (Open Font License / Apache 2.0)
