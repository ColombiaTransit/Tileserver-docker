#!/usr/bin/env python3
"""Bouwt de styles, sprites, fonts en config.json voor het tileserver-image.

Invoer (door de Dockerfile klaargezet in SRC):
  SRC/basic-preview/style.json            uit de tileserver-gl base image
  SRC/<style>/style.json + sprite*         upstream, op vaste commits
  SRC/<style>/LICENSE.md
  SRC/fonts.zip                            openmaptiles/fonts v2.0

Uitvoer (OUT, wordt /config in het image):
  OUT/config.json
  OUT/styles/<id>/style.json, sprite*.png/json, LICENSE.md
  OUT/fonts/<fontstack>/*.pbf              alleen de fonts die de styles gebruiken

Alle styles lezen de vector tiles uit data-id `v3` (colombia.mbtiles) en de
hoogtes uit `colombia-terrain` (colombia-terrain.mbtiles).
"""
import copy
import json
import shutil
import sys
import zipfile
from pathlib import Path

SRC = Path(sys.argv[1])
OUT = Path(sys.argv[2])

CENTER = [-74.3, 4.6]
ZOOM = 5.5

TERRAIN_SOURCE = {
    "type": "raster-dem",
    "url": "mbtiles://{colombia-terrain}",
    "tileSize": 256,
    "encoding": "mapbox",
}

# Hillshade-kleuren per style, afgestemd op het palet
HILLSHADE = {
    "basic-preview": {"shadow": "#5a5a5a", "highlight": "#ffffff", "accent": "#5a5a5a", "exaggeration": 0.35},
    "positron":      {"shadow": "#a8a8a8", "highlight": "#ffffff", "accent": "#a8a8a8", "exaggeration": 0.25},
    "dark-matter":   {"shadow": "#000000", "highlight": "#3c3c3c", "accent": "#000000", "exaggeration": 0.4},
    "osm-liberty":   {"shadow": "#473b24", "highlight": "#ffffff", "accent": "#aaaa99", "exaggeration": 0.35},
}

STYLES = {
    # id: (titel, sprite-bestandsnaam of None)
    "basic-preview": ("Basic", None),
    "positron":      ("Positron", "sprite"),
    "dark-matter":   ("Dark Matter", "sprite"),
    "osm-liberty":   ("OSM Liberty", "osm-liberty"),
}


def hillshade_layer(style_id):
    c = HILLSHADE[style_id]
    return {
        "id": "hillshade",
        "type": "hillshade",
        "source": "terrain",
        "paint": {
            "hillshade-exaggeration": c["exaggeration"],
            "hillshade-shadow-color": c["shadow"],
            "hillshade-highlight-color": c["highlight"],
            "hillshade-accent-color": c["accent"],
        },
    }


def first_line_or_symbol(layers):
    """Hillshade komt boven vlakken (land, water) en onder wegen en labels."""
    for i, layer in enumerate(layers):
        if layer.get("type") in ("line", "symbol", "fill-extrusion"):
            return i
    return len(layers)


def localize(style, style_id, title, has_sprite):
    s = copy.deepcopy(style)
    s["id"] = style_id
    s["name"] = title
    s["center"] = CENTER
    s["zoom"] = ZOOM
    s.pop("bearing", None)
    s.pop("pitch", None)

    for name, src in s["sources"].items():
        if src.get("type") == "vector":
            src.pop("tiles", None)
            src["url"] = "mbtiles://{v3}"

    # Externe Natural Earth-relief van OSM Liberty vervangen door eigen hillshade
    if "natural_earth_shaded_relief" in s["sources"]:
        del s["sources"]["natural_earth_shaded_relief"]
        idx = next(i for i, l in enumerate(s["layers"])
                   if l.get("source") == "natural_earth_shaded_relief")
        s["layers"] = [l for l in s["layers"] if l.get("source") != "natural_earth_shaded_relief"]
        s["sources"]["terrain"] = dict(TERRAIN_SOURCE)
        s["layers"].insert(idx, hillshade_layer(style_id))

    # Alles wat nog extern is, is een fout: het image moet zelfstandig werken
    for name, src in s["sources"].items():
        for u in [src.get("url", "")] + list(src.get("tiles", [])):
            if u.startswith("http"):
                raise SystemExit(f"{style_id}: externe bron {name}: {u}")

    s["glyphs"] = "{fontstack}/{range}.pbf"
    if has_sprite:
        s["sprite"] = "{styleJsonFolder}/sprite"
    else:
        s.pop("sprite", None)
    return s


def make_3d(style, style_id, title):
    s = copy.deepcopy(style)
    s["id"] = f"{style_id}-3d"
    s["name"] = f"{title} 3D"
    if "terrain" not in s["sources"]:
        s["sources"]["terrain"] = dict(TERRAIN_SOURCE)
        s["layers"].insert(first_line_or_symbol(s["layers"]), hillshade_layer(style_id))
    s["terrain"] = {"source": "terrain", "exaggeration": 1.3}
    return s


def collect_fonts(style, fonts):
    def walk(x):
        if isinstance(x, list):
            if x and all(isinstance(i, str) for i in x) and x[0] not in ("literal",):
                fonts.update(i for i in x if " " in i)
            for i in x:
                walk(i)
    for layer in style["layers"]:
        tf = layer.get("layout", {}).get("text-font")
        if tf is not None:
            walk(tf)


def main():
    styles_out = OUT / "styles"
    styles_out.mkdir(parents=True, exist_ok=True)
    config_styles = {}
    fonts = set()

    for style_id, (title, sprite_name) in STYLES.items():
        src_dir = SRC / style_id
        upstream = json.loads((src_dir / "style.json").read_text())
        flat = localize(upstream, style_id, title, sprite_name is not None)
        variants = [(style_id, flat), (f"{style_id}-3d", make_3d(flat, style_id, title))]

        for vid, style in variants:
            d = styles_out / vid
            d.mkdir(parents=True, exist_ok=True)
            (d / "style.json").write_text(json.dumps(style, indent=2, ensure_ascii=False))
            if sprite_name:
                for suffix in (".json", ".png", "@2x.json", "@2x.png"):
                    shutil.copy(src_dir / f"{sprite_name}{suffix}", d / f"sprite{suffix}")
            if (src_dir / "LICENSE.md").exists():
                shutil.copy(src_dir / "LICENSE.md", d / "LICENSE.md")
            collect_fonts(style, fonts)

            entry = {"style": f"{vid}/style.json"}
            # Server-side rendering alleen voor styles zonder hoogtedata;
            # raster-dem rendering op de server is niet getest.
            if "terrain" in style["sources"]:
                entry["serve_rendered"] = False
            config_styles[vid] = entry
            print(f"style {vid}: {len(style['layers'])} lagen")

    # Fonts: alleen de gebruikte fontstacks uitpakken
    fonts_out = OUT / "fonts"
    with zipfile.ZipFile(SRC / "fonts.zip") as z:
        available = {n.split("/")[0] for n in z.namelist() if "/" in n}
        missing = sorted(fonts - available)
        if missing:
            raise SystemExit(f"fonts ontbreken in fonts.zip: {missing}")
        for member in z.namelist():
            top = member.split("/")[0]
            if top in fonts and member.endswith(".pbf"):
                z.extract(member, fonts_out)
    print("fonts:", ", ".join(sorted(fonts)))

    config = {
        "options": {
            "paths": {
                "root": "/config",
                "styles": "styles",
                "sprites": "styles",
                "fonts": "fonts",
                "mbtiles": "/data",
            }
        },
        "styles": config_styles,
        "data": {
            "v3": {"mbtiles": "colombia.mbtiles"},
            "colombia-terrain": {
                "mbtiles": "colombia-terrain.mbtiles",
                "tileSize": 256,
                "sparse": False,
            },
        },
    }
    (OUT / "config.json").write_text(json.dumps(config, indent=2))


if __name__ == "__main__":
    main()
