# Tileserver-docker

Serveert vector tiles van Colombia met [TileServer GL](https://github.com/maptiler/tileserver-gl) achter Traefik op
`https://apiv2.colombiatransit.co/api/tiles/`.

De tiles komen uit [ColombiaTransit/colombia-mbtiles](https://github.com/ColombiaTransit/colombia-mbtiles), dat elke maandag een nieuwe `colombia.mbtiles` publiceert onder de release-tag `planetiler-latest`.

## Bestanden

| Bestand | Doel |
|---|---|
| `docker-compose.yml` | TileServer GL-container in het `traefik`-netwerk |
| `api-tileserver.yml` | Traefik-router en middlewares; kopieer naar de file-provider-map van Traefik (`/etc/traefik`) |
| `update-tiles.sh` | Downloadt de nieuwste tiles als de checksum verschilt, verifieert ze en herstart de container |
| `data/` | Hier komt `colombia.mbtiles` (niet in git) |

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

## Licentie van de data

Kaartdata © OpenStreetMap-bijdragers, beschikbaar onder [ODbL-1.0](https://opendatacommons.org/licenses/odbl/).
