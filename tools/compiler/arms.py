"""OSM often draws a bridge as a thin arm of the building it reaches (the E5 bridge
is part of E3's outline). The Path Map shows a bridge as a line and nothing else, so
those arms come out of the buildings.
"""

from __future__ import annotations

import math

from shapely.geometry import LineString, Polygon
from shapely.ops import unary_union

# Outline parts narrower than twice this are arms...
ARM_RADIUS = 3.0
# ...and one is a bridge when a bridge's line runs at least this far along it.
ARM_MIN_LENGTH = 2.0
# Pieces smaller than this, in square meters, are slivers left by the cut.
MIN_PIECE_AREA = 1.0


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


def polygons(geometry) -> list[Polygon]:
    """The polygons in any geometry (dropping lines and points)."""
    if geometry.is_empty:
        return []
    if isinstance(geometry, Polygon):
        return [geometry]
    return [p for g in getattr(geometry, "geoms", []) for p in polygons(g)]


def remove_bridge_arms(buildings: list[dict], connections: list[dict], frame: LocalFrame) -> None:
    """Cuts every bridge's arm out of the buildings it joins."""
    by_code = {b["code"]: b for b in buildings}
    for connection in connections:
        if connection["kind"] != "bridge" or not connection["paths"]:
            continue
        lines = [LineString([frame.to_meters(p) for p in path["points"]]) for path in connection["paths"]]
        for code in connection["buildings"]:
            building = by_code[code]
            body = outline(building, frame)
            opened = body.buffer(-ARM_RADIUS, join_style="mitre").buffer(ARM_RADIUS, join_style="mitre")
            arms = [thin for thin in polygons(body.difference(opened)) if sum(line.intersection(thin).length for line in lines) >= ARM_MIN_LENGTH]
            if arms:
                building["parts"] = _parts_without(building, unary_union(arms), frame)


def outline(building: dict, frame: LocalFrame):
    """The building's whole footprint, in meters."""
    return unary_union([_polygon(part, frame) for part in building["parts"]])


def _polygon(part: dict, frame: LocalFrame) -> Polygon:
    return Polygon([frame.to_meters(p) for p in part["outline"]], [[frame.to_meters(p) for p in hole] for hole in part["holes"]]).buffer(0)


def _parts_without(building: dict, arms, frame: LocalFrame) -> list[dict]:
    parts = []
    for part in building["parts"]:
        for piece in polygons(_polygon(part, frame).difference(arms)):
            if piece.area >= MIN_PIECE_AREA:
                parts.append({
                    **part,
                    "outline": [frame.to_lonlat(p) for p in piece.exterior.coords],
                    "holes": [[frame.to_lonlat(p) for p in ring.coords] for ring in piece.interiors],
                })
    return parts
