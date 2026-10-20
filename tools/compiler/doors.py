"""Doors: OSM entrances plus hand-made fixes from data/campus/doors.json.

Doors get stable IDs from their OSM node ("MC-n123456") so overrides and photo
folders survive re-imports. Names are generated from where the door sits on the
building ("North main entrance") until someone surveys it and sets a real one.
"""

from __future__ import annotations

import math
import re
from pathlib import Path

from issues import Issue

# OSM entrance=* value -> our kind.
KINDS = {"main": "main", "yes": "entrance", "secondary": "entrance", "exit": "exit", "staircase": "stairwell"}
KIND_VALUES = set(KINDS.values())
KIND_TITLES = {"main": "main entrance", "entrance": "entrance", "exit": "exit", "stairwell": "stairwell door"}
DIRECTIONS = ["North", "Northeast", "East", "Southeast", "South", "Southwest", "West", "Northwest"]
OVERRIDE_FIELDS = {"name", "kind", "level", "accessible", "verified", "hidden", "note"}
ADDED_FIELDS = OVERRIDE_FIELDS | {"id", "building", "coordinate"}
PHOTO_EXTENSIONS = {".jpg", ".jpeg", ".heic", ".png"}
DOOR_ID_PATTERN = re.compile(r"^[A-Z][A-Z0-9]{0,5}-[a-z0-9-]+$")


def door_id(code: str, osm_id: str) -> str:
    return f"{code}-n{osm_id.split('/')[1]}"


def accessible(wheelchair: str | None) -> bool | None:
    return {"yes": True, "designated": True, "no": False}.get(wheelchair or "")


def base_doors(entrances: list[dict]) -> list[dict]:
    doors = []
    for feature in entrances:
        p = feature["properties"]
        doors.append({
            "id": door_id(p["code"], p["osmId"]),
            "building": p["code"],
            "name": None,
            "kind": KINDS.get(p["entrance"], "entrance"),
            "coordinate": feature["geometry"]["coordinates"],
            "level": p.get("level"),
            "accessible": accessible(p.get("wheelchair")),
            "verified": False,
            "photos": [],
        })
    return doors


def apply_overrides(doors: list[dict], overrides: dict, building_codes: set[str], issues: list[Issue]) -> list[dict]:
    """Applies data/campus/doors.json: per-door edits, hidden doors, and doors OSM lacks."""
    by_id = {door["id"]: door for door in doors}
    for door_key, fields in overrides.get("doors", {}).items():
        if door_key not in by_id:
            issues.append(Issue("error", f"doors.json: no door {door_key} (deleted from OSM?)"))
            continue
        _check_fields(door_key, fields, OVERRIDE_FIELDS, issues)
        by_id[door_key].update({k: v for k, v in fields.items() if k != "note"})

    for added in overrides.get("added", []):
        added_id = added.get("id", "?")
        _check_fields(added_id, added, ADDED_FIELDS, issues)
        if not DOOR_ID_PATTERN.match(added_id) or added_id in by_id:
            issues.append(Issue("error", f"doors.json: added door id {added_id!r} is malformed or already used"))
            continue
        if added.get("building") not in building_codes:
            issues.append(Issue("error", f"doors.json: added door {added_id} has unknown building {added.get('building')!r}"))
            continue
        door = {"name": None, "kind": "entrance", "level": None, "accessible": None, "verified": False, "photos": []}
        door.update({k: v for k, v in added.items() if k != "note"})
        by_id[added_id] = door

    for door in by_id.values():
        if door["kind"] not in KIND_VALUES:
            issues.append(Issue("error", f"{door['id']}: unknown kind {door['kind']!r}"))
    return sorted((d for d in by_id.values() if not d.pop("hidden", False)), key=lambda d: (d["building"], d["id"]))


def _check_fields(door_key: str, fields: dict, allowed: set[str], issues: list[Issue]) -> None:
    for field in sorted(set(fields) - allowed):
        issues.append(Issue("error", f"doors.json: {door_key} has unknown field {field!r}"))


def outline_center(ring: list[list[float]]) -> tuple[float, float]:
    points = ring[:-1] if ring[0] == ring[-1] else ring
    return sum(p[0] for p in points) / len(points), sum(p[1] for p in points) / len(points)


def bearing(center: tuple[float, float], point: list[float]) -> float:
    """Compass bearing in degrees (0 = north, clockwise) from center to point."""
    dx = (point[0] - center[0]) * math.cos(math.radians(center[1]))
    dy = point[1] - center[1]
    return math.degrees(math.atan2(dx, dy)) % 360


def assign_names(doors: list[dict], centers: dict[str, tuple[float, float]]) -> None:
    """Names unnamed doors by direction, numbering clockwise where names repeat."""
    groups: dict[tuple[str, str], list[tuple[float, dict]]] = {}
    for door in doors:
        if door["name"]:
            continue
        angle = bearing(centers[door["building"]], door["coordinate"])
        direction = DIRECTIONS[int((angle + 22.5) // 45) % 8]
        name = f"{direction} {KIND_TITLES[door['kind']]}"
        groups.setdefault((door["building"], name), []).append((angle, door))
    for (_, name), members in groups.items():
        members.sort(key=lambda m: m[0])
        for number, (_, door) in enumerate(members, start=1):
            door["name"] = name if len(members) == 1 else f"{name} {number}"


def attach_photos(doors: list[dict], photos_dir: Path, issues: list[Issue]) -> list[tuple[Path, str]]:
    """Links data/photos/<door-id>/* to doors. Returns (source, bundle path) pairs to copy."""
    if not photos_dir.is_dir():
        return []
    by_id = {door["id"]: door for door in doors}
    copies = []
    for folder in sorted(p for p in photos_dir.iterdir() if p.is_dir()):
        door = by_id.get(folder.name)
        if door is None:
            issues.append(Issue("error", f"data/photos/{folder.name}: no door with that id"))
            continue
        for photo in sorted(folder.iterdir()):
            if photo.suffix.lower() in PHOTO_EXTENSIONS:
                bundle_path = f"photos/{folder.name}/{photo.name}"
                door["photos"].append(bundle_path)
                copies.append((photo, bundle_path))
    return copies
