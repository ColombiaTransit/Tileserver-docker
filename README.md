# Tileserver-docker

Docker-image met [TileServer GL](https://github.com/maptiler/tileserver-gl) voor Colombia, met styles, sprites en fonts ingebakken. Draait achter Traefik op `https://tileserver.colombiatransit.co/`.

```
ghcr.io/colombiatransit/tileserver-docker:latest
```

Gebaseerd op `maptiler/tileserver-gl:v5.7.0`. Het image wordt automatisch gebouwd en gepubliceerd bij elke push naar `main` die de `Dockerfile` of `docker/` raakt; zie [Image bouwen](#image-bouwen).

```
Cloudflare (cache)  ──►  Traefik v3 (headers, Cache-Control)  ──►  tileserver-gl  ──►  volume /data
                                                                     ▲ bij opstarten
                                     GitHub Releases: colombia-mbtiles, colombia-height
```

## Data

De `.mbtiles` zitten niet in het image. De container haalt ze **bij elke start** op en zet ze in het volume op `/data`:

| Data-id | Bestand | Bron |
|---|---|---|
| `v3` | `colombia.mbtiles` – OpenMapTiles vector tiles, ~430 MB | [colombia-mbtiles](https://github.com/ColombiaTransit/colombia-mbtiles), release `planetiler-latest` (elke maandag) |
| `colombia-terrain` | `colombia-terrain.mbtiles` – Terrain-RGB hoogtes, z0–13, ~4,2 GiB | [colombia-height](https://github.com/ColombiaTransit/colombia-height), release `latest` |

Bij het opstarten ([`docker/fetch-tiles.mjs`](docker/fetch-tiles.mjs)):

- de checksum van elke release wordt vergeleken met de opgeslagen `.sha256`; alleen bij een nieuwe versie of een ontbrekend bestand wordt gedownload;
- er wordt naar een tijdelijk bestand gedownload en pas na een geldige checksum vervangen (terrain: elk deel én het geheel);
- mislukt een update terwijl er al tiles zijn, dan start de tileserver met de oude versie;
- ontbreekt een bestand en lukt de download niet, dan stopt de container en probeert Docker het opnieuw.

De eerste start duurt een paar minuten (~4,6 GB). Reken op ~10 GiB vrije ruimte, want tijdens een terrain-update staat het bestand even dubbel op schijf. Met `TILES_UPDATE=false` wordt niets opgehaald.

Nieuwe tiles ophalen (vector tiles komen elke maandag uit) doe je met een herstart: `docker compose restart`.

## Styles

| Style | 2D | 3D (terrein + hillshade) |
|---|---|---|
| Positron (licht, rustig; goed onder routes en haltes) | `positron` | `positron-3d` |
| OSM Bright (volledige kaart, klassiek) | `osm-bright` | `osm-bright-3d` |
| OSM Liberty (volledige kaart, met hillshade) | `osm-liberty` | `osm-liberty-3d` |

Style-URL: `https://tileserver.colombiatransit.co/styles/<style>/style.json`

De upstream-styles worden tijdens het bouwen op vaste commits opgehaald en door [`docker/build_styles.py`](docker/build_styles.py) aangepast: bronnen naar de lokale data, eigen sprites en fonts, Colombia als startpositie, en voor de 3D-varianten terrein en hillshade. De natural-earth-relief van OSM Liberty is vervangen door hillshade uit `colombia-terrain`. Styles met hoogtedata worden alleen client-side gerenderd (`serve_rendered: false`).

## Installatie

Vereisten: Docker met Compose (of Portainer), Traefik **v3** met het externe netwerk `traefik` en de middlewares `real-ip` uit de bestaande Traefik-config, ~10 GiB vrije schijfruimte, en een DNS-record voor `tileserver.colombiatransit.co` in Cloudflare.

```bash
git clone https://github.com/ColombiaTransit/tileserver-docker.git
cd tileserver-docker
cp tileserver.yml /etc/traefik/       # map van de Traefik file-provider (watch: true)
docker compose up -d                  # haalt bij de eerste start de tiles op
docker compose logs -f                # voortgang van de download volgen
```

In Portainer: maak een stack met de inhoud van `docker-compose.yml`. Het image op GHCR is openbaar, dus er is geen registry-login nodig.

### Omgevingsvariabelen

| Variabele | Standaard | Doel |
|---|---|---|
| `PUBLIC_URL` | leeg | Basis-URL in styles en TileJSON, bijv. `https://tileserver.colombiatransit.co/` |
| `TILES_UPDATE` | `true` | `false` = bij het opstarten niets ophalen, alleen bestaande tiles gebruiken |
| `TILESERVER_GL_METRICS` | – | `true` = Prometheus-metrics van tileserver-gl aanzetten |

### Bijwerken

- **Tiles:** de vector tiles worden elke maandag om 05:25 UTC gebouwd. De container haalt ze op bij een herstart; plan die bijvoorbeeld met cron of een geplande taak in Portainer:

  ```cron
  0 9 * * 1 docker restart tileserver-colombia
  ```

- **Image** (nieuwe styles, tileserver-versie): `docker compose pull && docker compose up -d`, of *Pull and redeploy* in Portainer. De tiles in het volume blijven staan.

## Traefik

[`tileserver.yml`](tileserver.yml) gebruikt drie routers op dezelfde service, alleen om per soort bestand een passende `Cache-Control` te zetten; tileserver-gl doet dat zelf niet.

| Router | Paden | Cache-Control |
|---|---|---|
| `tileserver-tiles` | `/data/…/{z}/{x}/{y}.pbf\|png`, `/styles/…/{z}/{x}/{y}.png` | 1 dag, `stale-while-revalidate` 7 dagen |
| `tileserver-static` | `/fonts/…`, `/styles/…/sprite*` | 7 dagen |
| `tileserver` | de rest: `style.json`, TileJSON, viewer | 5 minuten |

Verder:

- **Compressie** voor JSON en fonts; afbeeldingen worden overgeslagen en vector tiles zijn al gzip.
- **Security-headers** (HSTS, `nosniff`, referrer-policy, `X-Robots-Tag`) zonder `frameDeny`, zodat kaarten in een iframe op andere sites mogen.
- **CORS** (`Access-Control-Allow-Origin: *`), `ETag` en `Last-Modified` komen van tileserver-gl.
- De routers gebruiken `PathRegexp` en vereisen daarom **Traefik v3**.

## Cloudflare

Cloudflare cachet standaard geen `.pbf` en `.json`. Eén Cache Rule laat Cloudflare de `Cache-Control` van Traefik volgen:

- **Expression:** `(http.host eq "tileserver.colombiatransit.co")`
- **Cache eligibility:** Eligible for cache
- **Edge TTL:** Use cache-control header if present, bypass cache if not
  - Status code TTL: **500–599 → No cache**, **404 → No cache** (Traefik zet de cache-header ook op foutmeldingen)
- **Browser TTL:** Respect origin TTL

Controleren:

```bash
curl -sI https://tileserver.colombiatransit.co/data/v3/10/301/497.pbf | grep -iE "cf-cache-status|cache-control"
```

De eerste aanvraag geeft `cf-cache-status: MISS`, de tweede `HIT`.

## Problemen oplossen

| Melding | Oorzaak en oplossing |
|---|---|
| `manifests/latest: unauthorized` bij pull | Het package op GHCR is privé. Zet het op openbaar (*Packages → tileserver-docker → Package settings → Change visibility*) of voeg `ghcr.io` als registry met een token (`read:packages`) toe in Portainer. |
| `[tiles] FOUT: ontbrekend in /data` | De eerste download is mislukt; Docker start de container opnieuw. Controleer de netwerkverbinding naar `github.com`. |
| `[tiles] … update mislukt`, daarna `Start met de bestaande tiles` | De nieuwe versie kon niet worden opgehaald of geverifieerd; de oude tiles blijven in gebruik. Bij de volgende start wordt het opnieuw geprobeerd. |
| `/data is niet schrijfbaar` | Bij een bind mount in plaats van het named volume: `sudo chown -R 1000:1000 ./data`. |
| 404 van Traefik | DNS, of `tileserver.yml` staat niet in de map van de file-provider. |
| 502/504 | Container draait niet of zit niet in het `traefik`-netwerk; tijdens de eerste download is de tileserver nog niet gestart. |

## Image bouwen

De workflow [`docker-image.yml`](.github/workflows/docker-image.yml) bouwt het image en publiceert het als `latest`, `v5.7.0` (tileserver-versie) en `sha-<commit>`. Daarna draaien twee rooktests:

1. met kleine test-tiles: alle styles aanwezig, sprites, fonts, terrain-tile en een server-side gerenderde tile;
2. met nep-releases: tiles ophalen bij het opstarten, vergelijken, en bij een herstart niets opnieuw downloaden.

Pull requests worden alleen gebouwd, niet gepubliceerd. Lokaal bouwen kan met `docker build -t tileserver-docker .` of door `build: .` aan te zetten in `docker-compose.yml`.

**Een style toevoegen of bijwerken:** zet de commit (en voor de sprite de `gh-pages`-commit) als `ARG` in de `Dockerfile`, haal de bestanden op in de download-stap, en voeg de style toe aan `STYLES` en `HILLSHADE` in [`docker/build_styles.py`](docker/build_styles.py). De build faalt als een style nog externe bronnen heeft of een font gebruikt dat niet in `openmaptiles/fonts` staat.

**tileserver-gl bijwerken:** pas `ARG TILESERVER_VERSION` in de `Dockerfile` aan.

## Bestanden

| Bestand | Doel |
|---|---|
| `Dockerfile` | Bouwt het image: haalt styles, sprites en fonts op en genereert `/config` |
| `docker/build_styles.py` | Zet de upstream-styles om en schrijft `config.json` |
| `docker/start.sh` | Entrypoint: tiles ophalen, daarna tileserver-gl starten met `--public_url` uit `PUBLIC_URL` |
| `docker/fetch-tiles.mjs` | Haalt bij het opstarten nieuwe `.mbtiles` op en verifieert ze |
| `docker/make_test_mbtiles.py` | Kleine test-data voor de rooktests in CI |
| `docker-compose.yml` | Container in het `traefik`-netwerk |
| `tileserver.yml` | Traefik-routers en middlewares voor `tileserver.colombiatransit.co` |
| `.github/workflows/docker-image.yml` | Bouwt, test en publiceert het image op GHCR |

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
- Styles: [Positron](https://github.com/openmaptiles/positron-gl-style) (code BSD-3-Clause, design onder CC-BY; © MapTiler/OpenMapTiles en CARTO), [OSM Bright](https://github.com/openmaptiles/osm-bright-gl-style) (code BSD-3-Clause, design onder CC-BY; © MapTiler/OpenMapTiles en Mapbox), [OSM Liberty](https://github.com/maputnik/osm-liberty) (BSD). De licentie van elke style staat in het image naast de style (`/config/styles/<id>/LICENSE.md`).
- Fonts: [openmaptiles/fonts](https://github.com/openmaptiles/fonts) (Open Font License / Apache 2.0)
