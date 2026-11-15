#!/usr/bin/env python3
"""Maakt twee kleine .mbtiles voor de rooktest in CI.

  colombia.mbtiles          OpenMapTiles-metadata, één lege vector tile (z0)
  colombia-terrain.mbtiles  één Terrain-RGB tile van 0 m (z0)
"""
import os
import sqlite3
import struct
import sys
import zlib

out = sys.argv[1]
os.makedirs(out, exist_ok=True)
BOUNDS = "-82,-4.3,-66.8,13.5"


def mbtiles(name, metadata, tile):
    path = os.path.join(out, name)
    if os.path.exists(path):
        os.remove(path)
    con = sqlite3.connect(path)
    con.execute("CREATE TABLE metadata (name TEXT, value TEXT)")
    con.execute("CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB)")
    con.executemany("INSERT INTO metadata VALUES (?, ?)", metadata.items())
    con.execute("INSERT INTO tiles VALUES (0, 0, 0, ?)", (tile,))
    con.commit()
    con.close()


def terrain_png():
    # Terrain-RGB 0 m = R,G,B 1,134,160 (mapbox: -10000 + (R*65536+G*256+B)*0.1)
    row = b"\x00" + b"\x01\x86\xa0" * 256
    raw = row * 256

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n"
            + chunk(b"IHDR", struct.pack(">IIBBBBB", 256, 256, 8, 2, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw))
            + chunk(b"IEND", b""))


mbtiles("colombia.mbtiles", {
    "name": "OpenMapTiles", "format": "pbf", "minzoom": "0", "maxzoom": "14",
    "bounds": BOUNDS,
    "json": '{"vector_layers":[{"id":"water","fields":{}}]}',
}, b"")

mbtiles("colombia-terrain.mbtiles", {
    "name": "colombia-terrain", "format": "png", "minzoom": "0", "maxzoom": "13",
    "bounds": BOUNDS,
}, terrain_png())

print("test-mbtiles gemaakt in", out)
