#!/usr/bin/env python3
"""Compile map source data (data/) into the bundle the app loads (build/CampusBundle).

Schema v10. campus.json: building shells (Tier 0) with every floor they have, the Path
Map's lines (corridors, each bridge's and tunnel's own, and the dividers between
buildings that touch), doors, building-to-building connections with the floor at each
end, and Popular places. graph.json: the walking graph routes are found on (graph.py).
"""

from __future__ import annotations

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

import connections as connections_module
import floors as floors_module
import lines as lines_module
from arms import LocalFrame, remove_bridge_arms
from dividers import dividers
from doors import apply_overrides, assign_names, attach_photos, base_doors, outline_center
from graph import build_graph
from issues import Issue
from shapely.geometry import Point, Polygon

REPO = Path(__file__).resolve().parents[2]
OUTPUT_DIR = REPO / "build/CampusBundle"
PHOTOS_DIR = REPO / "data/photos"
COVERAGE_PATH = REPO / "docs/coverage.md"
SURVEY_PATH = REPO / "docs/survey.md"
SCHEMA_VERSION = 10
DEFAULT_LEVELS = 2
GROUPS = {"core"}
CODE_PATTERN = re.compile(r"^[A-Z][A-Z0-9]{0,5}$")


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def validate(inventory: list[dict], features: list[dict]) -> list[Issue]:
    issues: list[Issue] = []
    codes: set[str] = set()
    names: dict[str, str] = {}  # lowercased code/alias -> owning building code

    for entry in inventory:
        code = entry["code"]
        if not CODE_PATTERN.match(code):
            issues.append(Issue("error", f"{code}: code must be 1-6 uppercase letters/digits"))
        if code in codes:
            issues.append(Issue("error", f"{code}: duplicate building code"))
        codes.add(code)
        if entry.get("group") not in GROUPS:
            issues.append(Issue("error", f"{code}: unknown group {entry.get('group')!r}"))
        if not 1 <= entry.get("priority", 0) <= 6:
            issues.append(Issue("error", f"{code}: priority must be 1-6"))
        for label in [code, *entry.get("aliases", [])]:
            owner = names.setdefault(label.lower(), code)
            if owner != code:
                issues.append(Issue("error", f"{code}: name {label!r} already used by {owner}"))

    parts_by_code: dict[str, list[dict]] = {}
    for feature in features:
        parts_by_code.setdefault(feature["properties"]["code"], []).append(feature)
    for code in sorted(codes):
        if code not in parts_by_code:
            issues.append(Issue("error", f"{code}: no outline in data/osm/buildings.geojson"))
    for code in sorted(set(parts_by_code) - codes):
        issues.append(Issue("error", f"{code}: outline has no inventory entry"))

    for entry in inventory:
        label = entry.get("label")
        if label is not None:
            if not (isinstance(label, list) and len(label) == 2 and all(isinstance(v, (int, float)) for v in label)):
                issues.append(Issue("error", f"{entry['code']}: label must be [lon, lat]"))
            elif not any(Polygon(f["geometry"]["coordinates"][0]).contains(Point(label)) for f in parts_by_code.get(entry["code"], [])):
                issues.append(Issue("warning", f"{entry['code']}: label is outside the building"))
        has_levels = entry.get("floors") or entry.get("levels") or any(
            f["properties"]["levels"] for f in parts_by_code.get(entry["code"], [])
        )
        if not has_levels:
            issues.append(Issue("warning", f"{entry['code']}: level count unknown, assuming {DEFAULT_LEVELS}"))
    return issues


def build_buildings(inventory: list[dict], features: list[dict]) -> list[dict]:
    buildings = []
    for entry in inventory:
        parts = [f for f in features if f["properties"]["code"] == entry["code"]]
        override = entry.get("levels")
        # The floor list is only known when Plant Operations publishes one.
        estimated = "floors" not in entry
        buildings.append({
            "code": entry["code"],
            "name": entry["name"],
            "aliases": entry.get("aliases", []),
            "group": entry["group"],
            "priority": entry["priority"],
            "levelsEstimated": estimated,
            **({"officialFloors": entry["floors"]} if "floors" in entry else {}),
            **({"label": entry["label"]} if "label" in entry else {}),
            "parts": [
                {
                    "osmId": p["properties"]["osmId"],
                    "levels": override or p["properties"]["levels"] or DEFAULT_LEVELS,
                    "outline": p["geometry"]["coordinates"][0],
                    "holes": p["geometry"]["coordinates"][1:],
                }
                for p in parts
            ],
        })
    return buildings


def assign_floors(buildings: list[dict], connections: list[dict], issues: list[Issue]) -> None:
    """Gives each building its floors, bottom to top, by short name and full title."""
    referenced: dict[str, set[str]] = {}
    for connection in connections:
        for end in connection["ends"]:
            referenced.setdefault(end["building"], set()).update(end["floors"])
    for b in buildings:
        above_ground = max(p.pop("levels") for p in b["parts"])
        names = floors_module.floor_names(above_ground, referenced.get(b["code"], set()), b["code"], issues, b.pop("officialFloors", None))
        b["floors"] = [{"name": name, "title": floors_module.title(name)} for name in names]


def drop_unknown_levels(doors: list[dict], buildings: list[dict]) -> None:
    """A door's level is only worth showing if it's one of the building's floors: OSM
    numbers floors from 0, which no sign on campus does."""
    floors = {b["code"]: {f["name"] for f in b["floors"]} for b in buildings}
    for door in doors:
        if door["level"] not in floors[door["building"]]:
            door["level"] = None


def floor_summary(building: dict) -> str:
    """Every floor, with runs of numbered floors shortened: "Basement, 1–6, Penthouse"."""
    parts, run = [], []

    def flush():
        if run:
            parts.append(run[0] if len(run) == 1 else f"{run[0]}–{run[-1]}")
            run.clear()

    for floor in building["floors"]:
        if floor["name"].isdigit() and (not run or int(floor["name"]) == int(run[-1]) + 1):
            run.append(floor["name"])
            continue
        flush()
        if floor["name"].isdigit():
            run.append(floor["name"])
        else:
            parts.append(floor["title"])
    flush()
    return ", ".join(parts)


def build_popular(popular: list[dict], building_codes: set[str], door_ids: set[str], issues: list[Issue]) -> list[dict]:
    places = []
    for entry in popular:
        if "building" in entry and entry["building"] in building_codes:
            places.append({"kind": "building", "id": entry["building"]})
        elif "door" in entry and entry["door"] in door_ids:
            places.append({"kind": "door", "id": entry["door"]})
        else:
            issues.append(Issue("error", f"popular.json: unknown place {entry}"))
    return places


def coverage_report(buildings: list[dict], doors: list[dict], connections: list[dict], routing: dict) -> str:
    """Markdown progress table: which detail tier each building has reached (docs/PLAN.md)."""
    rows = [
        "<!-- Generated by tools/compiler/compile.py. Do not edit. -->",
        "# Map coverage",
        "",
        "Tier 0 = shell, 1 = doors and connections verified.",
        "",
        "| Priority | Code | Name | Group | Tier | Floors | Doors (verified) | Connections (verified) | Photos |",
        "|---|---|---|---|---|---|---|---|---|",
    ]
    for b in sorted(buildings, key=lambda b: (b["priority"], b["code"])):
        own = [d for d in doors if d["building"] == b["code"]]
        verified = sum(d["verified"] for d in own)
        links = [c for c in connections if b["code"] in c["buildings"]]
        links_verified = sum(c["verified"] for c in links)
        tier = 1 if own and verified == len(own) and links_verified == len(links) else 0
        level_text = f"{floor_summary(b)} (estimated)" if b["levelsEstimated"] else floor_summary(b)
        photos = sum(len(d["photos"]) for d in own)
        rows.append(
            f"| {b['priority']} | {b['code']} | {b['name']} | {b['group']} | {tier} | {level_text} "
            f"| {len(own)} ({verified}) | {len(links)} ({links_verified}) | {photos} |"
        )
    undrawn = [c for c in connections if c["kind"] != "link" and not c["paths"]]
    rows += ["", "## Bridges and tunnels with no line", "", "Known, but not drawn on the Path Map, because their route isn't mapped.", ""]
    rows += [f"- `{c['id']}`: {c['name']}" for c in undrawn] or ["None."]
    rows += [
        "",
        "## Routing",
        "",
        "Buildings with no lines: routes end at their doors. Doors that are missing a join are",
        "still on the map, but routes can't go through them on that side.",
        "",
        f"- Buildings with no lines: {', '.join(routing['noLines']) or 'none'}",
        f"- Doors with no way to a corridor: {', '.join(routing['noWayIn']) or 'none'}",
        f"- Doors with no way to a footpath: {', '.join(routing['noWayOut']) or 'none'}",
        f"- Doors cut off from everything: {', '.join(routing['cutOff']) or 'none'}",
    ]
    return "\n".join(rows) + "\n"


def survey_checklist(buildings: list[dict], doors: list[dict], connections: list[dict]) -> str:
    """Markdown checklist for the Tier 1 walk: every unverified door and connection."""
    rows = [
        "<!-- Generated by tools/compiler/compile.py. Do not edit. -->",
        "# Tier 1 survey checklist",
        "",
        "For each door and connection still listed, check it on site, then record it in",
        "`data/campus/doors.json` / `data/campus/connections.json` by id:",
        "",
        "- **Door:** a real `name` (\"North entrance\" → what the sign says, e.g. \"Comfy lounge doors\"), `kind`",
        "  (`main`, `entrance`, `exit`, `stairwell`), `level` as signed inside, `accessible` (step-free?),",
        "  then `\"verified\": true`. Doors that don't exist: `\"hidden\": true`. Doors missing here: add",
        "  them under `added`. Photos (one outside, one inside) go in `data/photos/<id>/`.",
        "- **Connection:** `ends`, the floor it meets in each building as signed there (`{\"MC\": [\"3\"], \"QNC\": [\"2\"]}`;",
        "  a two-storey bridge lists both), `closed` if locked or under construction, `hidden` if it isn't real,",
        "  then `\"verified\": true`.",
        "",
        "Run `make data` afterwards; this list shrinks as things are verified.",
    ]
    for b in sorted(buildings, key=lambda b: (b["priority"], b["code"])):
        open_doors = [d for d in doors if d["building"] == b["code"] and not d["verified"]]
        open_links = [c for c in connections if b["code"] == c["buildings"][0] and not c["verified"]]
        if not open_doors and not open_links:
            continue
        rows += ["", f"## {b['code']} · {b['name']}", ""]
        for d in open_doors:
            lon, lat = d["coordinate"]
            details = ", ".join(filter(None, [d["kind"], f"level {d['level']}" if d["level"] else None]))
            rows.append(f"- [ ] `{d['id']}`: {d['name']} ({details}) · [map](https://www.openstreetmap.org/?mlat={lat}&mlon={lon}#map=20/{lat}/{lon})")
        for c in open_links:
            ends = ", ".join(f"{e['building']} {','.join(e['floors']) or '?'}" for e in c["ends"])
            rows.append(f"- [ ] `{c['id']}`: {c['name']}, {c['kind']} joining {ends}")
    return "\n".join(rows) + "\n"


def source_hash() -> str:
    return subprocess.check_output([str(REPO / "tools/source_hash.sh")], text=True).strip()


def main() -> int:
    campus = load_json(REPO / "data/campus/campus.json")
    inventory = load_json(REPO / "data/campus/inventory.json")["buildings"]
    features = load_json(REPO / "data/osm/buildings.geojson")["features"]
    entrances = load_json(REPO / "data/osm/entrances.geojson")["features"]
    door_overrides = load_json(REPO / "data/campus/doors.json")
    connection_features = load_json(REPO / "data/osm/connections.geojson")["features"]
    connection_overrides = load_json(REPO / "data/campus/connections.json")
    popular = load_json(REPO / "data/campus/popular.json")["places"]
    lines = load_json(REPO / "data/campus/lines.geojson")["features"]
    footpaths = load_json(REPO / "data/osm/footpaths.geojson")["features"]

    issues = validate(inventory, features)
    codes = {entry["code"] for entry in inventory}
    buildings = build_buildings(inventory, features)
    doors = apply_overrides(base_doors(entrances), door_overrides, codes, issues)
    assign_names(doors, {b["code"]: outline_center(b["parts"][0]["outline"]) for b in buildings})
    photo_copies = attach_photos(doors, PHOTOS_DIR, issues)
    popular_places = build_popular(popular, codes, {d["id"] for d in doors}, issues)
    connections = connections_module.apply_overrides(
        connections_module.base_connections(connection_features), connection_overrides, codes, issues
    )
    corridors = lines_module.attach_lines(connections, lines, issues)
    assign_floors(buildings, connections, issues)
    drop_unknown_levels(doors, buildings)
    frame = LocalFrame(campus["origin"])
    lines_module.check_corridors_inside(corridors, buildings, frame, issues)
    lines_module.check_lines_meet(lines, frame, issues)

    for issue in issues:
        print(f"{issue.severity}: {issue.message}", file=sys.stderr if issue.severity == "error" else sys.stdout)
    if any(issue.severity == "error" for issue in issues):
        return 1

    remove_bridge_arms(buildings, connections, frame)
    walking_graph, routing = build_graph(buildings, doors, connections, corridors, footpaths, frame, campus["origin"]["latitude"], issues)
    for issue in issues:
        if issue.message.startswith("graph:"):
            print(f"{issue.severity}: {issue.message}")
    shutil.rmtree(OUTPUT_DIR, ignore_errors=True)
    OUTPUT_DIR.mkdir(parents=True)
    bundle = {
        "schemaVersion": SCHEMA_VERSION,
        "origin": campus["origin"],
        "attribution": "© OpenStreetMap contributors",
        "buildings": buildings,
        "corridors": corridors,
        "dividers": dividers(buildings, frame),
        "doors": doors,
        "connections": connections,
        "popular": popular_places,
    }
    (OUTPUT_DIR / "campus.json").write_text(json.dumps(bundle, separators=(",", ":")), encoding="utf-8")
    graph_file = {"schemaVersion": SCHEMA_VERSION, **walking_graph}
    (OUTPUT_DIR / "graph.json").write_text(json.dumps(graph_file, separators=(",", ":")), encoding="utf-8")
    for source, bundle_path in photo_copies:
        destination = OUTPUT_DIR / bundle_path
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "sourceHash": source_hash(),
        "buildingCount": len(buildings),
        "doorCount": len(doors),
        "connectionCount": len(connections),
        "graphNodeCount": len(walking_graph["nodes"]),
        "graphEdgeCount": len(walking_graph["edges"]),
    }
    (OUTPUT_DIR / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n", encoding="utf-8")
    COVERAGE_PATH.write_text(coverage_report(buildings, doors, connections, routing), encoding="utf-8")
    SURVEY_PATH.write_text(survey_checklist(buildings, doors, connections), encoding="utf-8")
    print(
        f"Compiled {len(buildings)} buildings, {len(doors)} doors, {len(connections)} connections, "
        f"{len(walking_graph['edges'])} graph edges, {len(photo_copies)} photos into {OUTPUT_DIR.relative_to(REPO)}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
