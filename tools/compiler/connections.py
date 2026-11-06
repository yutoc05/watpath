"""Bridges, tunnels and links between buildings: OSM candidates plus hand fixes
and additions from data/campus/connections.json.

Each connection lists its ends: a building and the floor (or floors, for a
two-storey bridge) it meets there, as signed in that building. OSM rarely knows
these; they're recorded by hand and checked in the Tier 1 survey. What the map
draws for a connection comes from data/campus/lines.geojson (see lines.py).
"""

from __future__ import annotations

from issues import Issue

KINDS = {"bridge", "tunnel", "link"}
OVERRIDE_FIELDS = {"name", "kind", "ends", "verified", "closed", "hidden", "note"}
ADDED_FIELDS = OVERRIDE_FIELDS | {"id"}


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
            "paths": [],
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
        if not fields.get("ends"):
            issues.append(Issue("error", f"connections.json: added {connection_id} needs ends"))
            continue
        by_id[connection_id] = {
            "id": connection_id,
            "kind": fields.get("kind", "link"),
            "name": fields.get("name"),
            "ends": fields["ends"],
            "verified": fields.get("verified", False),
            "closed": fields.get("closed", False),
            "paths": [],
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
