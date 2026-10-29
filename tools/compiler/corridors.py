"""Indoor corridors: the hand-drawn center lines in data/campus/corridors.geojson
(one feature per building floor), turned into what the Path Map draws on each
floor: a corridor floor area (as triangles) and walls along its sides.

Each center line is widened to a corridor, and all corridors on one floor of a
building are merged, so walls follow the outside of junctions instead of cutting
across them. Walls are left out where a corridor ends (at a bridge, a tunnel,
stairs or a door) and where it meets the building's own outside wall.
"""

from __future__ import annotations

import math
from collections import defaultdict

import shapely
from shapely.geometry import LineString, MultiLineString, Point, Polygon
from shapely.ops import unary_union

from issues import Issue

CORRIDOR_WIDTH = 3.0
# Corridors may run this far past the building outline, to meet bridges and doors on it.
OUTLINE_MARGIN = 0.5
# Line ends closer than this to another line on the same floor are junctions.
JUNCTION_METERS = 0.75
# No wall within this of an open corridor end or the building's outside wall.
WALL_GAP = 0.3


class LocalFrame:
    """Meters east/north of the campus origin (equirectangular: exact enough over campus)."""

    def __init__(self, origin: dict):
        self.lat0, self.lon0 = origin["latitude"], origin["longitude"]
        self.kx = 111_320 * math.cos(math.radians(self.lat0))
        self.ky = 110_574

    def to_meters(self, point: list[float]) -> tuple[float, float]:
        return ((point[0] - self.lon0) * self.kx, (point[1] - self.lat0) * self.ky)

    def to_lonlat(self, point: tuple[float, float]) -> list[float]:
        return [round(self.lon0 + point[0] / self.kx, 7), round(self.lat0 + point[1] / self.ky, 7)]


def add_corridors(buildings: list[dict], features: list[dict], frame: LocalFrame, issues: list[Issue]) -> None:
    """Adds `corridor` ({"triangles", "walls"}) to every building floor with drawn corridors."""
    by_code = {b["code"]: b for b in buildings}
    lines: dict[tuple[str, str], list[LineString]] = defaultdict(list)
    for feature in features:
        code, name = feature["properties"].get("building"), str(feature["properties"].get("floor"))
        building = by_code.get(code)
        if building is None:
            issues.append(Issue("error", f"corridors.geojson: unknown building {code!r}"))
            continue
        floor = next((f for f in building["floors"] if f["name"] == name), None)
        if floor is None:
            issues.append(Issue("error", f"corridors.geojson: {code} has no floor {name!r}"))
            continue
        if not floor.get("mapped", True):
            issues.append(Issue("error", f"corridors.geojson: {code} floor {name} isn't on the Path Map (no bridge, tunnel or link meets it)"))
            continue
        geometry = feature["geometry"]
        parts = [geometry["coordinates"]] if geometry["type"] == "LineString" else geometry["coordinates"]
        lines[(code, name)] += [LineString([frame.to_meters(p) for p in part]) for part in parts if len(part) >= 2]

    for (code, name), floor_lines in sorted(lines.items()):
        building = by_code[code]
        outline = unary_union([Polygon([frame.to_meters(p) for p in part["outline"]]).buffer(0) for part in building["parts"]])
        corridor = corridor_geometry(floor_lines, outline)
        if corridor is None:
            issues.append(Issue("warning", f"corridors.geojson: {code} floor {name} has no corridor inside the building"))
            continue
        area, walls = corridor
        floor = next(f for f in building["floors"] if f["name"] == name)
        floor["corridor"] = {
            "triangles": [[frame.to_lonlat(p) for p in triangle.exterior.coords[:3]] for triangle in _triangles(area)],
            "walls": [[frame.to_lonlat(p) for p in wall.coords] for wall in _line_parts(walls)],
        }


def corridor_geometry(lines: list[LineString], outline) -> tuple | None:
    """The merged corridor area for one floor's center lines, and its walls."""
    lines = [line for line in lines if line.length > 0.01]
    if not lines:
        return None
    half = CORRIDOR_WIDTH / 2
    pieces = [line.buffer(half, cap_style="flat", join_style="mitre", mitre_limit=2.0) for line in lines]
    open_ends = []
    for index, line in enumerate(lines):
        others = unary_union([other for j, other in enumerate(lines) if j != index])
        for end, inward in ((line.coords[0], line.coords[1]), (line.coords[-1], line.coords[-2])):
            if not others.is_empty and Point(end).distance(others) <= JUNCTION_METERS:
                # Where lines meet end to end, square off the joint so it has no notch.
                pieces.append(Point(end).buffer(half, cap_style="square"))
            else:
                open_ends.append(_cap(end, inward, half))
    area = unary_union(pieces).intersection(outline.buffer(OUTLINE_MARGIN))
    if area.is_empty or area.area < 1:
        return None
    # The outline's own wall stands where a corridor reaches it, out to the margin it may run past it.
    no_wall = unary_union([outline.boundary.buffer(OUTLINE_MARGIN + WALL_GAP)] + [cap.buffer(WALL_GAP) for cap in open_ends])
    walls = area.boundary.difference(no_wall)
    return area, walls


def _cap(end: tuple[float, float], inward: tuple[float, float], half: float) -> LineString:
    """The flat end of a corridor: a segment across it, through `end`."""
    dx, dy = end[0] - inward[0], end[1] - inward[1]
    length = math.hypot(dx, dy) or 1.0
    nx, ny = -dy / length * (half + WALL_GAP), dx / length * (half + WALL_GAP)
    return LineString([(end[0] + nx, end[1] + ny), (end[0] - nx, end[1] - ny)])


def _triangles(area) -> list[Polygon]:
    return [g for g in shapely.constrained_delaunay_triangles(area).geoms if g.area > 1e-6]


def _line_parts(geometry) -> list[LineString]:
    if geometry.is_empty:
        return []
    if isinstance(geometry, LineString):
        return [geometry] if geometry.length > 0.01 else []
    if isinstance(geometry, MultiLineString):
        merged = shapely.line_merge(geometry)
        return _line_parts(merged) if not isinstance(merged, MultiLineString) else [g for g in merged.geoms if g.length > 0.01]
    if hasattr(geometry, "geoms"):
        return [part for g in geometry.geoms for part in _line_parts(g)]
    return []
