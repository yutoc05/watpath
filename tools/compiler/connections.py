"""Bridges, tunnels and links between buildings: OSM candidates plus hand fixes
and additions from data/campus/connections.json.

Each connection lists its ends: a building and the floor (or floors, for a
two-storey bridge) it meets there, as signed in that building. OSM rarely knows
these; they're recorded by hand and checked in the Tier 1 survey.
"""

from __future__ import annotations

import math

from issues import Issue

KINDS = {"bridge", "tunnel", "link"}
OVERRIDE_FIELDS = {"name", "kind", "ends", "verified", "closed", "hidden", "note"}
ADDED_FIELDS = OVERRIDE_FIELDS | {"id", "path"}
# A path ending in two different buildings beats one that's this much closer to a
# single building at both ends.
SAME_END_PENALTY_METERS = 5.0


def base_connections(features: list[dict]) -> list[dict]:
    connections = []
    for feature in features:
        p = feature["properties"]
        connections.append({
            "id": p["id"],
            "kind": p["kind"],
            "name": p.get("name"),
            "ends": {code: [] for code in p["buildings"]},
            "verified": False,
            "closed": False,
            "paths": feature["geometry"]["coordinates"],
        })
    return connections


def apply_overrides(connections: list[dict], overrides: dict, codes: set[str], issues: list[Issue]) -> list[dict]:
    by_id = {c["id"]: c for c in connections}
    for connection_id, fields in overrides.get("connections", {}).items():
        connection = by_id.get(connection_id)
        if connection is None:
            issues.append(Issue("error", f"connections.json: no connection {connection_id} (deleted from OSM?)"))
            continue
        for field in sorted(set(fields) - OVERRIDE_FIELDS):
            issues.append(Issue("error", f"connections.json: {connection_id} has unknown field {field!r}"))
        connection.update({k: v for k, v in fields.items() if k in OVERRIDE_FIELDS - {"note"}})
    for fields in overrides.get("added", []):
        connection_id = fields.get("id", "?")
        for field in sorted(set(fields) - ADDED_FIELDS):
            issues.append(Issue("error", f"connections.json: added {connection_id} has unknown field {field!r}"))
        if connection_id in by_id:
            issues.append(Issue("error", f"connections.json: added {connection_id} reuses an id"))
            continue
        if not fields.get("ends") or len(fields.get("path", [])) < 2:
            issues.append(Issue("error", f"connections.json: added {connection_id} needs ends and a path"))
            continue
        by_id[connection_id] = {
            "id": connection_id,
            "kind": fields.get("kind", "link"),
            "name": fields.get("name"),
            "ends": fields["ends"],
            "verified": fields.get("verified", False),
            "closed": fields.get("closed", False),
            "paths": [fields["path"]],
            "hidden": fields.get("hidden", False),
        }

    compiled = []
    for connection in by_id.values():
        if connection.pop("hidden", False):
            continue
        if connection["kind"] not in KINDS:
            issues.append(Issue("error", f"{connection['id']}: unknown kind {connection['kind']!r}"))
        for code, floors in connection["ends"].items():
            if code not in codes:
                issues.append(Issue("error", f"{connection['id']}: unknown building {code}"))
            if not isinstance(floors, list) or not all(isinstance(f, str) for f in floors):
                issues.append(Issue("error", f"{connection['id']}: floors for {code} must be a list of strings"))
        buildings = list(connection["ends"])
        if not connection["name"]:
            connection["name"] = f"{'–'.join(buildings)} {connection['kind']}"
        connection["buildings"] = buildings
        connection["ends"] = [{"building": code, "floors": floors} for code, floors in connection["ends"].items()]
        compiled.append(connection)
    return sorted(compiled, key=lambda c: (c["buildings"], c["id"]))


def attach_paths(connections: list[dict], outlines: dict[str, list[list[list[float]]]]) -> None:
    """Says which end each path starts and finishes at, so the app knows the floor
    (and height) at both: the ends whose buildings are nearest, preferring two
    different ends, since outlines often overlap where a bridge meets them."""
    for connection in connections:
        ends = range(len(connection["ends"]))
        attached = []
        for points in connection["paths"]:
            start = [distance_to_building(points[0], outlines.get(e["building"], [])) for e in connection["ends"]]
            finish = [distance_to_building(points[-1], outlines.get(e["building"], [])) for e in connection["ends"]]
            i, j = min(
                ((i, j) for i in ends for j in ends),
                key=lambda pair: start[pair[0]] + finish[pair[1]] + (SAME_END_PENALTY_METERS if pair[0] == pair[1] else 0),
            )
            attached.append({"points": points, "from": i, "to": j})
        connection["paths"] = attached


def distance_to_building(point: list[float], rings: list[list[list[float]]]) -> float:
    """Meters from `point` to the nearest outline edge (0 inside)."""
    if any(contains(ring, point) for ring in rings):
        return 0.0
    scale = 111_320 * math.cos(math.radians(point[1]))
    px, py = point[0] * scale, point[1] * 110_574
    best = math.inf
    for ring in rings:
        for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
            ax, ay, bx, by = x0 * scale, y0 * 110_574, x1 * scale, y1 * 110_574
            dx, dy = bx - ax, by - ay
            t = 0.0 if dx == dy == 0 else max(0.0, min(1.0, ((px - ax) * dx + (py - ay) * dy) / (dx * dx + dy * dy)))
            best = min(best, math.hypot(px - (ax + t * dx), py - (ay + t * dy)))
    return best


def contains(ring: list[list[float]], point: list[float]) -> bool:
    x, y = point
    inside = False
    for (x0, y0), (x1, y1) in zip(ring, ring[1:]):
        if (y0 > y) != (y1 > y) and x < x0 + (y - y0) * (x1 - x0) / (y1 - y0):
            inside = not inside
    return inside
