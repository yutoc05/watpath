"""The walking graph the app routes on (build/CampusBundle/graph.json): the Path Map's
lines indoors, OSM's footpaths outdoors, joined at doors.

The Path Map is flat, but people aren't: a bridge leaves MC from floor 3 and reaches
QNC on floor 2. So an edge that changes floors says so, as `floors`: one [enter, exit]
pair per way across it, in storeys, read from `a` to `b`. A two-storey bridge has two
pairs. Null means nobody knows, and is never charged for. Everything else keeps
whatever floor you were on, which is what lets the router charge for the stairs
between two connections in one building (docs/adr/003-routing.md).

Where a corridor runs from one building into the next, each side gets its own node,
joined by a zero-length `link` edge that carries the floors between them.
"""

from __future__ import annotations

import math
from collections import Counter, defaultdict
from dataclasses import dataclass, field

from arms import LocalFrame, outline
from floors import ordinal
from issues import Issue
from shapely.geometry import LineString, Point
from shapely.ops import unary_union
from shapely.strtree import STRtree

# A stretch shorter than this, in meters, doesn't count as entering a building:
# corridors run along shared walls, and outlines aren't exact.
MIN_STRETCH = 2.0
# How far a corridor may be from an outline and still belong to that building.
OWNER_REACH = 5.0
# A door joins the footpaths along a straight line of at most this many meters...
DOOR_REACH = 60.0
# ...which may clip a building by this much: doors sit on outlines.
DOOR_CLIP = 1.0
# A stub from a door to a corridor may leave the building's outline by this much.
STUB_MARGIN = 1.0
# A line this close to an outline reaches a building that has no lines of its own.
ANCHOR_REACH = 1.5
# Splitting an edge this close to its end just uses the end.
END_TOLERANCE = 0.05


Coordinate = tuple[float, float]  # (lon, lat)


def meters_per_degree(latitude: float) -> tuple[float, float]:
    """True ground distance per degree (east, north), from the WGS84 series."""
    phi = math.radians(latitude)
    east = 111_412.84 * math.cos(phi) - 93.5 * math.cos(3 * phi) + 0.118 * math.cos(5 * phi)
    north = 111_132.92 - 559.82 * math.cos(2 * phi) + 1.175 * math.cos(4 * phi) - 0.0023 * math.cos(6 * phi)
    return east, north


def true_length(points: list[Coordinate], latitude: float) -> float:
    east, north = meters_per_degree(latitude)
    return sum(math.hypot((b[0] - a[0]) * east, (b[1] - a[1]) * north) for a, b in zip(points, points[1:]))


@dataclass
class Edge:
    a: int
    b: int
    kind: str  # corridor, door (from a corridor to a door), bridge, tunnel, link or outdoor
    points: list[Coordinate]  # from a to b, ends included
    building: str | None = None
    floors: list[list[float | None]] | None = None
    one_way: bool = False  # only from a to b
    # The building at each end, for edges that join two.
    ends: tuple[str | None, str | None] = (None, None)


@dataclass
class Graph:
    frame: LocalFrame
    nodes: list[Coordinate] = field(default_factory=list)
    edges: list[Edge] = field(default_factory=list)

    def add_node(self, point: Coordinate) -> int:
        self.nodes.append(point)
        return len(self.nodes) - 1

    def meters(self, points: list[Coordinate]) -> LineString:
        return LineString([self.frame.to_meters(list(p)) for p in points])

    def point_at(self, line: LineString, offset: float) -> Coordinate:
        where = line.interpolate(offset)
        return tuple(self.frame.to_lonlat((where.x, where.y)))

    def add_lines(self, lines: list[tuple[list[Coordinate], dict]]) -> None:
        """Adds lines that meet only at shared vertices, cutting each one at them.
        `attrs` may hold `span`, a function from (is first piece, is last piece) to
        attributes that depend on where along the line a piece is."""
        uses = Counter(point for points, _ in lines for point in points)
        at: dict[Coordinate, int] = {}

        def node(point: Coordinate) -> int:
            if point not in at:
                at[point] = self.add_node(point)
            return at[point]

        for points, attrs in lines:
            attrs = dict(attrs)
            span = attrs.pop("span", None)
            piece = [points[0]]
            first = True
            for index, point in enumerate(points[1:], start=1):
                piece.append(point)
                last = index == len(points) - 1
                if uses[point] > 1 or last:
                    extra = span(first, last) if span else {}
                    self.edges.append(Edge(node(piece[0]), node(piece[-1]), points=piece, **attrs, **extra))
                    piece, first = [point], False

    def split(self, requests: list[tuple[int, float]]) -> list[int]:
        """Cuts edges at (edge index, offset in meters) and returns the node at each.
        Offsets are measured from `a` along the edge. Requests against one edge are
        handled together, so edge indices stay valid until this returns."""
        results = [-1] * len(requests)
        by_edge: dict[int, list[tuple[float, int]]] = defaultdict(list)
        for request, (edge_index, offset) in enumerate(requests):
            by_edge[edge_index].append((offset, request))

        for edge_index in sorted(by_edge):
            edge = self.edges[edge_index]
            line = self.meters(edge.points)
            cuts: list[tuple[float, int]] = []  # offset, node
            for offset, request in sorted(by_edge[edge_index]):
                if offset <= END_TOLERANCE:
                    results[request] = edge.a
                elif offset >= line.length - END_TOLERANCE:
                    results[request] = edge.b
                elif cuts and offset - cuts[-1][0] <= END_TOLERANCE:
                    results[request] = cuts[-1][1]
                else:
                    results[request] = self.add_node(self.point_at(line, offset))
                    cuts.append((offset, results[request]))
            if not cuts:
                continue

            vertices = [line.project(Point(c)) for c in line.coords]
            remaining = list(zip(vertices[1:-1], edge.points[1:-1]))
            pieces, start_node, start_point = [], edge.a, edge.points[0]
            for offset, node in cuts:
                cut_point = self.nodes[node]
                inner = [point for vertex, point in remaining if vertex < offset]
                remaining = [(vertex, point) for vertex, point in remaining if vertex >= offset]
                pieces.append((start_node, node, [start_point, *inner, cut_point]))
                start_node, start_point = node, cut_point
            pieces.append((start_node, edge.b, [start_point, *[point for _, point in remaining], edge.points[-1]]))

            edge.b, edge.points = pieces[0][1], pieces[0][2]
            for a, b, points in pieces[1:]:
                self.edges.append(Edge(a, b, edge.kind, points, edge.building, edge.floors, edge.one_way))
        return results


def stretches(line: LineString, shapes: dict[str, object]) -> list[tuple[float, float, str | None]]:
    """Runs along `line`, as (start, end, building), in meters. Where two buildings
    overlap (EV3 over EV2), the smaller one has it: the larger still has the rest."""
    cuts = {0.0, line.length}
    for shape in shapes.values():
        crossing = line.intersection(shape.boundary)
        for piece in getattr(crossing, "geoms", [crossing]):
            if not piece.is_empty:
                cuts.update(line.project(Point(c)) for c in piece.coords)
    positions = sorted(cuts)

    runs: list[list] = []
    for start, end in zip(positions, positions[1:]):
        if end - start < 1e-6:
            continue
        middle = line.interpolate((start + end) / 2)
        inside = [code for code, shape in shapes.items() if shape.contains(middle)]
        previous = runs[-1][2] if runs else None
        owner = min(inside, key=lambda code: shapes[code].area) if inside else previous
        if runs and runs[-1][2] == owner:
            runs[-1][1] = end
        else:
            runs.append([start, end, owner])

    # Short runs join what's around them, shortest first.
    while len(runs) > 1:
        shortest = min(range(len(runs)), key=lambda i: runs[i][1] - runs[i][0])
        if runs[shortest][1] - runs[shortest][0] >= MIN_STRETCH:
            break
        neighbor = shortest - 1 if shortest > 0 else shortest + 1
        low, high = sorted((shortest, neighbor))
        runs[low:high + 1] = [[runs[low][0], runs[high][1], runs[neighbor][2]]]
        for index in range(len(runs) - 1, 0, -1):
            if runs[index][2] == runs[index - 1][2]:
                runs[index - 1:index + 1] = [[runs[index - 1][0], runs[index][1], runs[index][2]]]

    owner = next((run[2] for run in runs if run[2] is not None), None)
    if owner is None:  # the whole line is just outside: take the nearest building
        code, distance = min(((c, s.distance(line)) for c, s in shapes.items()), key=lambda item: item[1], default=(None, math.inf))
        owner = code if distance <= OWNER_REACH else None
    return [(run[0], run[1], run[2] if run[2] is not None else owner) for run in runs]


def cut_by_building(points: list[Coordinate], shapes: dict[str, object], graph: Graph) -> list[tuple[list[Coordinate], str | None]]:
    """A corridor as pieces with one building each."""
    line = graph.meters(points)
    runs = stretches(line, shapes)
    if len(runs) == 1:
        return [(points, runs[0][2])]
    offsets = [line.project(Point(c)) for c in line.coords]

    def at(position: float) -> Coordinate:
        """The vertex there, if there is one, so nothing moves."""
        near = (point for offset, point in zip(offsets, points) if abs(offset - position) <= END_TOLERANCE)
        return next(near, None) or graph.point_at(line, position)

    # Each cut is one point, so the pieces either side of it meet exactly.
    cuts = [at(runs[0][0]), *[at(run[1]) for run in runs]]
    return [
        ([cuts[i], *[p for offset, p in zip(offsets, points) if start + END_TOLERANCE < offset < end - END_TOLERANCE], cuts[i + 1]], owner)
        for i, (start, end, owner) in enumerate(runs)
    ]


def connection_floors(connection: dict, start: int | None, finish: int | None) -> list[list[float | None]]:
    """[enter, exit] for each way across, walking from end `start` to end `finish`.
    A junction (None) sits level with the first end, which is as good as any: a
    connection doesn't change floors partway, it only has different names at each end."""
    ends = connection["ends"]
    count = max(len(end["floors"]) for end in ends)

    def level(end: int | None, index: int) -> float | None:
        floors = ends[0 if end is None else end]["floors"]
        return ordinal(floors[index]) if index < len(floors) else None

    return [[level(start, i), level(finish, i)] for i in range(count)] or [[None, None]]


def link_floors(a: str, b: str, connections: list[dict]) -> list[list[float | None]] | None:
    """The floors a corridor crosses between buildings `a` and `b`, or None if the data
    has no link between them."""
    for connection in connections:
        if connection["kind"] != "link" or not {a, b} <= set(connection["buildings"]):
            continue
        ends = [connection["buildings"].index(a), connection["buildings"].index(b)]
        floors = connection_floors(connection, *ends)
        if floors != [[None, None]]:
            return floors
    return None


def indoor_lines(corridors: list[list], connections: list[dict], shapes: dict[str, object], graph: Graph) -> list[tuple]:
    lines: list[tuple[list[Coordinate], dict]] = []
    for corridor in corridors:
        for points, owner in cut_by_building([tuple(p) for p in corridor], shapes, graph):
            lines.append((points, {"kind": "corridor", "building": owner, "ends": (owner, owner)}))
    for connection in connections:
        if connection["closed"]:
            continue
        for path in connection["paths"]:
            start, finish = path["from"], path["to"]

            def span(first: bool, last: bool, start=start, finish=finish, connection=connection) -> dict:
                head, tail = start if first else None, finish if last else None
                codes = [e["building"] for e in connection["ends"]]
                return {
                    "floors": connection_floors(connection, head, tail),
                    "ends": (codes[head] if head is not None else None, codes[tail] if tail is not None else None),
                }

            lines.append(([tuple(p) for p in path["points"]], {"kind": connection["kind"], "span": span}))
    return lines


def separate_buildings(graph: Graph, connections: list[dict], issues: list[Issue]) -> None:
    """Gives each building its own node where lines from two buildings meet, joined
    by a zero-length link that carries the floors."""
    meeting: dict[int, dict[str, list[tuple[Edge, int]]]] = defaultdict(lambda: defaultdict(list))
    for edge in graph.edges:
        for side, (node, code) in enumerate(zip((edge.a, edge.b), edge.ends)):
            if code is not None:
                meeting[node][code].append((edge, side))

    for node in sorted(meeting):
        codes = sorted(meeting[node])
        for code in codes[1:]:
            twin = graph.add_node(graph.nodes[node])
            for edge, side in meeting[node][code]:
                if side == 0:
                    edge.a = twin
                else:
                    edge.b = twin
            floors = link_floors(codes[0], code, connections)
            if floors is None:
                issues.append(Issue("warning", f"graph: lines join {codes[0]} and {code}, which no connection links"))
            where = graph.nodes[node]
            graph.edges.append(Edge(node, twin, "link", [where, where], floors=floors or [[None, None]]))


def nearest_on(edge_index: int, line: LineString, point: Point) -> tuple[float, int, float]:
    offset = line.project(point)
    return (line.interpolate(offset).distance(point), edge_index, offset)


def indoor_join(door: dict, candidates: list[tuple[int, LineString]], shape, graph: Graph) -> tuple[int, float] | None:
    """Where a straight line from the door reaches one of its building's corridors
    without leaving the building: the nearest such point on any corridor, or at any bend."""
    origin = Point(graph.frame.to_meters(door["coordinate"]))
    lines = dict(candidates)
    points = [nearest_on(index, line, origin) for index, line in candidates]
    for index, line in candidates:
        for offset in (line.project(Point(c)) for c in line.coords):
            points.append((line.interpolate(offset).distance(origin), index, offset))
    room = shape.buffer(STUB_MARGIN)
    for distance, index, offset in sorted(points):
        if distance < 0.01 or LineString([origin, lines[index].interpolate(offset)]).within(room):
            return index, offset
    return None


def outdoor_join(door: dict, lines: list[LineString], tree: STRtree, walls, graph: Graph) -> tuple[int, float] | None:
    """Where a straight line from the door reaches a footpath, without crossing `walls`
    if there are any."""
    origin = Point(graph.frame.to_meters(door["coordinate"]))
    nearby = tree.query(origin.buffer(DOOR_REACH))
    for distance, index, offset in sorted(nearest_on(int(i), lines[int(i)], origin) for i in nearby):
        if distance > DOOR_REACH:
            break
        stub = LineString([origin, lines[index].interpolate(offset)])
        if distance < 0.01 or walls is None or stub.intersection(walls).length <= DOOR_CLIP:
            return index, offset
    return None


def keep_largest_component(graph: Graph, kinds: set[str] | None = None) -> set[int]:
    """Drops what can't reach the rest, like neighbourhood streets that fall inside the
    import's bounding box, and returns the nodes that stay. With `kinds`, it only looks
    at edges of those kinds, and leaves the others alone."""
    parent = list(range(len(graph.nodes)))

    def root(node: int) -> int:
        while parent[node] != node:
            parent[node] = parent[parent[node]]
            node = parent[node]
        return node

    considered = [edge for edge in graph.edges if kinds is None or edge.kind in kinds]
    for edge in considered:
        parent[root(edge.a)] = root(edge.b)
    sizes = Counter(root(edge.a) for edge in considered)
    largest = max(sorted(sizes), key=lambda r: sizes[r])
    graph.edges = [edge for edge in graph.edges if (kinds is not None and edge.kind not in kinds) or root(edge.a) == largest]
    return {node for node in range(len(graph.nodes)) if root(node) == largest}


def build_graph(
    buildings: list[dict],
    doors: list[dict],
    connections: list[dict],
    corridors: list[list],
    footpaths: list[dict],
    frame: LocalFrame,
    latitude: float,
    issues: list[Issue],
) -> tuple[dict, dict]:
    """The graph as the app reads it, and notes on it for docs/coverage.md."""
    graph = Graph(frame)
    shapes = {b["code"]: outline(b, frame) for b in buildings}

    graph.add_lines(indoor_lines(corridors, connections, shapes, graph))
    separate_buildings(graph, connections, issues)
    graph.add_lines([([tuple(p) for p in f["geometry"]["coordinates"]], {"kind": "outdoor"}) for f in footpaths])

    keep_largest_component(graph, kinds={"outdoor"})

    # Everything that splits an edge goes in one list, since splitting renumbers nothing.
    through: dict[str, list[tuple[int, LineString]]] = defaultdict(list)  # corridors in each building
    outdoor: list[int] = []
    for index, edge in enumerate(graph.edges):
        if edge.kind == "corridor":
            line = graph.meters(edge.points)
            for code, shape in shapes.items():
                if code == edge.building or line.intersection(shape).length >= MIN_STRETCH:
                    through[code].append((index, line))
        elif edge.kind == "outdoor":
            outdoor.append(index)
    outdoor_lines = [graph.meters(graph.edges[i].points) for i in outdoor]
    tree = STRtree(outdoor_lines)
    walls = unary_union(list(shapes.values())).buffer(-0.5)

    requests: list[tuple[int, float]] = []
    inward: dict[str, int] = {}
    outward: dict[str, int] = {}
    no_way_in, no_way_out = [], []
    for door in doors:
        if door["building"] in through:
            join = indoor_join(door, through[door["building"]], shapes[door["building"]], graph)
            if join is None:
                no_way_in.append(door["id"])
            else:
                inward[door["id"]] = len(requests)
                requests.append(join)
        join = outdoor_join(door, outdoor_lines, tree, walls, graph)
        if join is None:
            no_way_out.append(door["id"])
            # A door with no way in or out is still a place to go, so it joins the
            # nearest footpath even if that means crossing a corner of the building.
            if door["id"] not in inward:
                join = outdoor_join(door, outdoor_lines, tree, None, graph)
        if join is not None:
            outward[door["id"]] = len(requests)
            requests.append((outdoor[join[0]], join[1]))

    hearts: dict[str, int] = {}
    fallbacks: dict[str, int] = {}
    for building in buildings:
        code = building["code"]
        target = Point(frame.to_meters(building["label"])) if "label" in building else shapes[code].centroid
        if code in through:
            _, index, offset = min(nearest_on(i, line, target) for i, line in through[code])
            hearts[code] = len(requests)
            requests.append((index, offset))
        elif not any(d["building"] == code for d in doors):
            _, index, offset = min(nearest_on(i, line, target) for i, line in enumerate(outdoor_lines))
            fallbacks[code] = len(requests)
            requests.append((outdoor[index], offset))

    nodes = graph.split(requests)

    door_nodes: dict[str, int] = {}
    for door in doors:
        point = tuple(door["coordinate"])
        node = door_nodes[door["id"]] = graph.add_node(point)
        # Outside there's no floor, and only a surveyed door has one worth trusting.
        floor = ordinal(door["level"]) if door["verified"] and door["level"] else None
        if door["id"] in inward:
            # Read from inside out, so an exit-only door lets people out but not in.
            target = nodes[inward[door["id"]]]
            graph.edges.append(Edge(target, node, "door", [graph.nodes[target], point], door["building"], [[floor, None]], door["kind"] == "exit"))
        if door["id"] in outward:
            target = nodes[outward[door["id"]]]
            graph.edges.append(Edge(node, target, "outdoor", [point, graph.nodes[target]]))

    kept = keep_largest_component(graph)
    anchors = {}
    for building in buildings:
        code = building["code"]
        if code in hearts:
            anchors[code] = [nodes[hearts[code]]]
            continue
        places = [door_nodes[d["id"]] for d in doors if d["building"] == code]
        # Lines that reach a building with none of its own, like the SLC corridor at PAC.
        near = shapes[code].buffer(ANCHOR_REACH)
        for edge in graph.edges:
            if edge.kind in ("corridor", "door"):
                places += [n for n in (edge.a, edge.b) if near.contains(Point(frame.to_meters(list(graph.nodes[n]))))]
        if code in fallbacks:
            places.append(nodes[fallbacks[code]])
        anchors[code] = sorted(set(places))

    door_map = {door_id: node for door_id, node in door_nodes.items() if node in kept}
    cut_off = sorted(set(door_nodes) - set(door_map))
    anchors = {code: [n for n in places if n in kept] for code, places in anchors.items()}
    for code, places in anchors.items():
        if not places:
            issues.append(Issue("warning", f"graph: {code} can't be reached"))

    used = sorted(kept)
    renumber = {old: new for new, old in enumerate(used)}
    edges = []
    for edge in graph.edges:
        record: dict = {"a": renumber[edge.a], "b": renumber[edge.b], "kind": edge.kind, "length": round(true_length(edge.points, latitude), 2)}
        if len(edge.points) > 2:
            record["points"] = [list(p) for p in edge.points[1:-1]]
        if edge.building:
            record["building"] = edge.building
        if edge.floors:
            record["floors"] = edge.floors
        if edge.one_way:
            record["oneWay"] = True
        edges.append(record)
    compiled = {
        "nodes": [list(graph.nodes[old]) for old in used],
        "edges": edges,
        "doors": {door_id: renumber[node] for door_id, node in sorted(door_map.items())},
        "buildings": {
            code: {"anchors": [renumber[n] for n in places], "hasLines": code in through}
            for code, places in sorted(anchors.items())
        },
    }
    notes = {
        "noWayIn": sorted(no_way_in),
        "noWayOut": sorted(no_way_out),
        "cutOff": cut_off,
        "noLines": sorted(set(shapes) - set(through)),
    }
    return compiled, notes
