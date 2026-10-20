#!/usr/bin/env python3
"""Import building outlines for the in-scope inventory from OpenStreetMap.

Writes data/osm/buildings.geojson, a generated file: never hand-edit it, re-run
this script instead. Output is sorted and one feature per line so diffs stay
readable. Map data © OpenStreetMap contributors, ODbL.

Usage:
    python3 tools/osm_import/import_osm.py            # fetch from Overpass
    python3 tools/osm_import/import_osm.py --offline  # reuse build/cache response
"""

from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
INVENTORY_PATH = REPO / "data/campus/inventory.json"
OUTPUT_PATH = REPO / "data/osm/buildings.geojson"
CACHE_PATH = REPO / "build/cache/overpass-buildings.json"

# south, west, north, east. Covers the main campus, East Campus and the athletics fields.
BBOX = (43.4640, -80.5530, 43.4790, -80.5350)
ENDPOINTS = (
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
)
USER_AGENT = "WatPath/0.1 (https://github.com/yutoc05/watpath)"
COORDINATE_DIGITS = 7

Point = tuple[float, float]  # (lon, lat), GeoJSON order
Ring = list[Point]


def overpass_query() -> str:
    s, w, n, e = BBOX
    return (
        "[out:json][timeout:90];"
        f'(way["building"]({s},{w},{n},{e});relation["building"]({s},{w},{n},{e}););'
        "out geom;"
    )


def fetch_overpass(query: str, attempts: int = 4) -> dict:
    body = urllib.parse.urlencode({"data": query}).encode()
    delay = 5.0
    last_error: Exception | None = None
    for attempt in range(attempts):
        endpoint = ENDPOINTS[attempt % len(ENDPOINTS)]
        request = urllib.request.Request(endpoint, data=body, headers={"User-Agent": USER_AGENT})
        try:
            with urllib.request.urlopen(request, timeout=120) as response:
                return json.load(response)
        except (urllib.error.URLError, json.JSONDecodeError, TimeoutError) as error:
            last_error = error
            print(f"Overpass request to {endpoint} failed ({error}); retrying in {delay:.0f}s", file=sys.stderr)
            time.sleep(delay)
            delay *= 2
    raise RuntimeError(f"Overpass unavailable after {attempts} attempts: {last_error}")


def geometry_points(geometry: list[dict]) -> list[Point]:
    return [(node["lon"], node["lat"]) for node in geometry]


def assemble_rings(segments: list[list[Point]]) -> list[Ring]:
    """Join open way segments end to end into closed rings (multipolygon members)."""
    remaining = [list(segment) for segment in segments if len(segment) >= 2]
    rings: list[Ring] = []
    while remaining:
        ring = remaining.pop(0)
        while ring[0] != ring[-1]:
            for index, segment in enumerate(remaining):
                if segment[0] == ring[-1]:
                    ring.extend(segment[1:])
                elif segment[-1] == ring[-1]:
                    ring.extend(reversed(segment[:-1]))
                else:
                    continue
                remaining.pop(index)
                break
            else:
                break  # Broken relation: drop the unclosed ring rather than invent geometry.
        if ring[0] == ring[-1] and len(ring) >= 4:
            rings.append(ring)
    return rings


def signed_area(ring: Ring) -> float:
    return 0.5 * sum(x0 * y1 - x1 * y0 for (x0, y0), (x1, y1) in zip(ring, ring[1:]))


def oriented(ring: Ring, counter_clockwise: bool) -> Ring:
    is_ccw = signed_area(ring) > 0
    return ring if is_ccw == counter_clockwise else list(reversed(ring))


def contains(ring: Ring, point: Point) -> bool:
    x, y = point
    inside = False
    for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            inside = not inside
    return inside


def element_polygons(element: dict) -> list[list[Ring]]:
    """Polygons as [outer, *holes], outer CCW and holes CW per RFC 7946."""
    if element["type"] == "way":
        rings = assemble_rings([geometry_points(element.get("geometry", []))])
        return [[oriented(ring, True)] for ring in rings]

    members = [m for m in element.get("members", []) if m.get("type") == "way" and m.get("geometry")]
    outers = assemble_rings([geometry_points(m["geometry"]) for m in members if m.get("role") != "inner"])
    inners = assemble_rings([geometry_points(m["geometry"]) for m in members if m.get("role") == "inner"])
    polygons = [[oriented(outer, True)] for outer in outers]
    for inner in inners:
        for polygon in polygons:
            if contains(polygon[0], inner[0]):
                polygon.append(oriented(inner, False))
                break
    return polygons


def parse_int(value: str | None) -> int | None:
    try:
        return int(float(value)) if value is not None else None
    except ValueError:
        return None


def matches(entry: dict, tags: dict) -> bool:
    # type=building relations group 3D building:part shapes; their footprint is a
    # separate "outline" element carrying the same ref, which is what we want.
    if tags.get("building") == "bridge" or tags.get("type") == "building":
        return False
    rule = entry["osm"]
    if "ref" in rule:
        return tags.get("ref") == rule["ref"]
    if "name" in rule:
        return tags.get("name") == rule["name"]
    return False


def rounded(ring: Ring) -> list[list[float]]:
    return [[round(lon, COORDINATE_DIGITS), round(lat, COORDINATE_DIGITS)] for lon, lat in ring]


def build_features(inventory: list[dict], elements: list[dict]) -> tuple[list[dict], list[str]]:
    features: list[dict] = []
    missing: list[str] = []
    for entry in inventory:
        found = [el for el in elements if matches(entry, el.get("tags", {}))]
        if not found:
            missing.append(entry["code"])
        for element in found:
            tags = element.get("tags", {})
            for index, polygon in enumerate(element_polygons(element)):
                features.append({
                    "type": "Feature",
                    "properties": {
                        "code": entry["code"],
                        "osmId": f'{element["type"]}/{element["id"]}',
                        "part": index,
                        "levels": parse_int(tags.get("building:levels")),
                        "minLevel": parse_int(tags.get("building:min_level")),
                        "osmName": tags.get("name"),
                    },
                    "geometry": {"type": "Polygon", "coordinates": [rounded(ring) for ring in polygon]},
                })
    features.sort(key=lambda f: (f["properties"]["code"], f["properties"]["osmId"], f["properties"]["part"]))
    return features, missing


def write_feature_collection(path: Path, features: list[dict]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [json.dumps(feature, separators=(",", ":"), sort_keys=True) for feature in features]
    header = '{"type":"FeatureCollection","attribution":"© OpenStreetMap contributors, ODbL","features":[\n'
    path.write_text(header + ",\n".join(lines) + "\n]}\n", encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--offline", action="store_true", help="reuse the cached Overpass response")
    args = parser.parse_args()

    if args.offline:
        response = json.loads(CACHE_PATH.read_text(encoding="utf-8"))
    else:
        response = fetch_overpass(overpass_query())
        CACHE_PATH.parent.mkdir(parents=True, exist_ok=True)
        CACHE_PATH.write_text(json.dumps(response), encoding="utf-8")

    inventory = json.loads(INVENTORY_PATH.read_text(encoding="utf-8"))["buildings"]
    features, missing = build_features(inventory, response.get("elements", []))
    write_feature_collection(OUTPUT_PATH, features)

    matched = len(inventory) - len(missing)
    print(f"Wrote {len(features)} outline parts for {matched}/{len(inventory)} buildings to {OUTPUT_PATH.relative_to(REPO)}")
    no_levels = sorted({f["properties"]["code"] for f in features if f["properties"]["levels"] is None})
    if no_levels:
        print(f"No building:levels in OSM (compiler will estimate): {', '.join(no_levels)}")
    if missing:
        print(f"error: no OSM outline for: {', '.join(missing)}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
