"""The Path Map's lines (data/campus/lines.geojson): one flat network of corridors,
bridges and tunnels, drawn by hand from mapped routes. Where a route isn't known
there is no line, so a connection may have none.

Each feature says what it is. A bridge or tunnel also names its connection and the
building at each end, which is where the floor numbers go; a corridor is just a line.
"""

from __future__ import annotations

from issues import Issue

KINDS = {"corridor", "bridge", "tunnel"}


def attach_lines(connections: list[dict], features: list[dict], issues: list[Issue]) -> list[list]:
    """Gives each bridge and tunnel its `paths` and returns the corridors. A path's
    `from` and `to` index its connection's ends; null is a junction (the T in the
    ML–AL–EV1 tunnel)."""
    by_id = {c["id"]: c for c in connections}
    corridors = []
    for index, feature in enumerate(features):
        properties = feature["properties"]
        kind = properties.get("kind")
        points = feature["geometry"]["coordinates"]
        where = f"lines.geojson feature {index}"
        if kind not in KINDS:
            issues.append(Issue("error", f"{where}: unknown kind {kind!r}"))
            continue
        if len(points) < 2:
            issues.append(Issue("error", f"{where}: a line needs two points"))
            continue
        if kind == "corridor":
            if "connection" in properties:
                issues.append(Issue("error", f"{where}: a corridor doesn't belong to a connection"))
            corridors.append(points)
            continue
        connection = by_id.get(properties.get("connection"))
        if connection is None:
            issues.append(Issue("error", f"{where}: no connection {properties.get('connection')!r}"))
            continue
        if connection["kind"] != kind:
            issues.append(Issue("error", f"{where}: {connection['id']} is a {connection['kind']}, not a {kind}"))
            continue
        ends = [e["building"] for e in connection["ends"]]
        unknown = [code for code in (properties.get("from"), properties.get("to")) if code is not None and code not in ends]
        if unknown:
            issues.append(Issue("error", f"{where}: {connection['id']} doesn't reach {unknown[0]}"))
            continue
        start, finish = (ends.index(code) if code is not None else None for code in (properties.get("from"), properties.get("to")))
        connection["paths"].append({"points": points, "from": start, "to": finish})
    return corridors
