"""The Path Map's lines (data/campus/lines.geojson): one flat network of corridors,
bridges and tunnels, drawn by hand from mapped routes. Where a route isn't known
there is no line, so a connection may have none.

Each feature says what it is. A bridge or tunnel also names its connection and the
building at each end, which is where the floor numbers go; a corridor is just a line,
and it stays inside buildings.
"""

from __future__ import annotations

from arms import LocalFrame, outline
from issues import Issue
from shapely.geometry import LineString
from shapely.ops import unary_union

KINDS = {"corridor", "bridge", "tunnel"}
# A corridor may leave a building by this much, in meters: outlines aren't exact.
OUTSIDE_TOLERANCE = 0.3


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


def check_corridors_inside(corridors: list[list], buildings: list[dict], frame: LocalFrame, issues: list[Issue]) -> None:
    """A corridor outside every building is a mistake: only bridges and tunnels are."""
    inside = unary_union([outline(b, frame) for b in buildings])
    for corridor in corridors:
        outside = LineString([frame.to_meters(p) for p in corridor]).difference(inside)
        for piece in getattr(outside, "geoms", [outside]):
            if piece.length > OUTSIDE_TOLERANCE:
                east, north = piece.coords[0]
                issues.append(Issue("error", f"lines.geojson: a corridor runs {piece.length:.1f} m outside the buildings at {frame.to_lonlat((east, north))}"))
