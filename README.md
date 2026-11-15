# Tileserver-docker

Serveert vector tiles van Colombia met [TileServer GL](https://github.com/maptiler/tileserver-gl) achter Traefik op
`https://apiv2.colombiatransit.co/api/tiles/`.

Er worden twee datasets geserveerd:

| Data-id | Bestand | Bron |
|---|---|---|
| `v3` | `colombia.mbtiles` – OpenMapTiles vector tiles | [colombia-mbtiles](https://github.com/ColombiaTransit/colombia-mbtiles), release `planetiler-latest` (elke maandag) |
| `colombia-terrain` | `colombia-terrain.mbtiles` – Terrain-RGB hoogtes, z0–13, ~4,2 GiB | [colombia-height](https://github.com/ColombiaTransit/colombia-height), release `latest` |

En twee styles:

- `basic-preview` – de standaard style van TileServer GL
- `colombia-3d` – dezelfde style met hillshade en 3D-terrein (alleen client-side; geen server-side rendering)

## Bestanden

| Bestand | Doel |
|---|---|
| `docker-compose.yml` | TileServer GL-container in het `traefik`-netwerk |
| `config.json` | TileServer GL-config: datasets, styles en paden |
| `styles/colombia-3d/` | 3D-style (afgeleid van basic-preview, zie LICENSE.md) |
| `api-tileserver.yml` | Traefik-router en middlewares; kopieer naar de file-provider-map van Traefik (`/etc/traefik`) |
| `update-tiles.sh` | Downloadt nieuwe vector- en terrain-tiles als de checksum verschilt, verifieert ze en herstart de container (vereist `python3`) |
| `data/` | Hier komen de `.mbtiles`-bestanden (niet in git). Reken op ~10 GiB vrije ruimte tijdens een terrain-update |

## Installatie

```bash
./update-tiles.sh          # eerste download
docker compose up -d
```

Wekelijks bijwerken via cron, ruim na de build van maandag 05:25 UTC:

```cron
0 9 * * 1 /pad/naar/tileserver-docker/update-tiles.sh >> /var/log/update-tiles.log 2>&1
```

## Testen

- Overzicht en viewer: `https://apiv2.colombiatransit.co/api/tiles/`
- Style voor MapLibre: `https://apiv2.colombiatransit.co/api/tiles/styles/basic-preview/style.json`
- 3D-style: `https://apiv2.colombiatransit.co/api/tiles/styles/colombia-3d/style.json`
- Terrain TileJSON: `https://apiv2.colombiatransit.co/api/tiles/data/colombia-terrain.json`

Terrein toevoegen aan een eigen MapLibre-style:

```js
map.addSource('terrain', {
  type: 'raster-dem',
  url: 'https://apiv2.colombiatransit.co/api/tiles/data/colombia-terrain.json',
  tileSize: 256,
  encoding: 'mapbox'
});
map.setTerrain({ source: 'terrain', exaggeration: 1.3 });
```

Buiten Colombiaans land geeft de terrain-data HTTP 204 (geen tile). De vlakke zee is alleen voor weergave, geen bathymetrie; daarom staat `encoding` bewust niet in de server-config (geen elevation-API).

## Licentie van de data

Kaartdata © OpenStreetMap-bijdragers, beschikbaar onder [ODbL-1.0](https://opendatacommons.org/licenses/odbl/). Hoogtedata: Copernicus DEM GLO-30, zie [colombia-height](https://github.com/ColombiaTransit/colombia-height/blob/main/release/DATA_LICENSE.md).
