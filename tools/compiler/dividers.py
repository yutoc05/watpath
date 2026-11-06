"""Where two buildings touch, a hairline keeps them apart on the Path Map: otherwise
they'd merge into one grey shape. Buildings that overlap (EV3 was built over part of
EV2) are drawn as one block, with no line through them.
"""

from __future__ import annotations

from itertools import combinations

import shapely
from arms import LocalFrame, outline
from shapely.geometry import LineString, MultiLineString

# Outlines this far apart, in meters, still count as touching: they aren't exact.
TOUCH_METERS = 0.3
# Sharing more than this many square meters makes a pair overlap, not touch.
OVERLAP_AREA = 1.0
# Shorter contact than this, in meters, isn't a wall between them.
MIN_LENGTH = 1.0


def dividers(buildings: list[dict], frame: LocalFrame) -> list[list[list[float]]]:
    shapes = [outline(b, frame) for b in buildings]
    result = []
    for a, b in combinations(shapes, 2):
        if a.intersection(b).area > OVERLAP_AREA:
            continue
        for line in _lines(a.boundary.intersection(b.buffer(TOUCH_METERS))):
            if line.length >= MIN_LENGTH:
                result.append([frame.to_lonlat(p) for p in line.coords])
    return result


def _lines(geometry) -> list[LineString]:
    if isinstance(geometry, LineString):
        return [geometry]
    if isinstance(geometry, MultiLineString):
        merged = shapely.line_merge(geometry)
        return [merged] if isinstance(merged, LineString) else list(merged.geoms)
    return [line for part in getattr(geometry, "geoms", []) for line in _lines(part)]
