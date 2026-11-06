import math

from arms import LocalFrame
from graph import Graph, build_graph, connection_floors, link_floors, meters_per_degree, stretches, true_length
from shapely.geometry import LineString, Polygon

ORIGIN = {"latitude": 43.47, "longitude": -80.54}
FRAME = LocalFrame(ORIGIN)


def at(east, north):
    """A coordinate this many meters from the origin."""
    return FRAME.to_lonlat((east, north))


def building(code, west, south, east, north, **extra):
    corners = [at(west, south), at(east, south), at(east, north), at(west, north), at(west, south)]
    return {"code": code, "parts": [{"outline": corners, "holes": []}], **extra}


def door(door_id, code, east, north, kind="entrance", level=None, verified=False):
    return {"id": door_id, "building": code, "kind": kind, "coordinate": at(east, north), "level": level, "verified": verified}


def footpath(*points):
    return {"geometry": {"coordinates": [at(*p) for p in points]}}


def connection(connection_id, kind, ends, paths=(), closed=False):
    return {
        "id": connection_id,
        "kind": kind,
        "closed": closed,
        "buildings": list(ends),
        "ends": [{"building": code, "floors": floors} for code, floors in ends.items()],
        "paths": list(paths),
    }


def compile_graph(buildings, doors=(), connections=(), corridors=(), footpaths=()):
    issues = []
    corridor_lines = [[at(*p) for p in line] for line in corridors]
    graph, notes = build_graph(list(buildings), list(doors), list(connections), corridor_lines, list(footpaths), FRAME, ORIGIN["latitude"], issues)
    return graph, notes, issues


def edges_of(graph, kind):
    return [edge for edge in graph["edges"] if edge["kind"] == kind]


def test_true_length_uses_the_real_size_of_a_degree():
    east, north = meters_per_degree(43.47)
    assert abs(east - 80_910) < 20
    assert abs(north - 111_100) < 20
    assert abs(true_length([(0, 43.47), (0.001, 43.47)], 43.47) - east / 1000) < 1e-9


def test_a_corridor_in_one_building_is_one_stretch():
    shape = Polygon([(0, 0), (100, 0), (100, 50), (0, 50)])
    assert stretches(LineString([(10, 25), (90, 25)]), {"MC": shape}) == [(0.0, 80.0, "MC")]


def test_a_corridor_across_two_buildings_changes_owner_at_the_wall():
    shapes = {"A": Polygon([(0, 0), (50, 0), (50, 50), (0, 50)]), "B": Polygon([(50, 0), (100, 0), (100, 50), (50, 50)])}
    assert stretches(LineString([(10, 25), (90, 25)]), shapes) == [(0.0, 40.0, "A"), (40.0, 80.0, "B")]


def test_grazing_a_neighbor_for_a_moment_doesnt_count():
    shapes = {"A": Polygon([(0, 0), (50, 0), (50, 50), (0, 50)]), "B": Polygon([(50, 0), (100, 0), (100, 50), (50, 50)])}
    assert [run[2] for run in stretches(LineString([(10, 25), (51, 25)]), shapes)] == ["A"]


def test_where_buildings_overlap_the_smaller_one_owns_the_corridor():
    shapes = {"BIG": Polygon([(0, 0), (100, 0), (100, 50), (0, 50)]), "SMALL": Polygon([(50, 0), (100, 0), (100, 50), (50, 50)])}
    assert [run[2] for run in stretches(LineString([(10, 25), (90, 25)]), shapes)] == ["BIG", "SMALL"]


def test_a_two_storey_bridge_has_two_ways_across():
    bridge = connection("c", "bridge", {"DC": ["1", "2"], "E3": ["2", "3"]})
    assert connection_floors(bridge, 0, 1) == [[1, 2], [2, 3]]
    assert connection_floors(bridge, 1, 0) == [[2, 1], [3, 2]]


def test_a_junction_sits_level_with_the_first_end():
    tunnel = connection("t", "tunnel", {"ML": ["1"], "AL": ["B"], "EV1": ["1"]})
    assert connection_floors(tunnel, 0, None) == [[1, 1]]
    assert connection_floors(tunnel, None, 1) == [[1, 0]]


def test_unknown_floors_stay_unknown():
    assert connection_floors(connection("c", "link", {"A": [], "B": []}), 0, 1) == [[None, None]]
    assert connection_floors(connection("c", "link", {"A": ["1"], "B": []}), 0, 1) == [[1, None]]


def test_link_floors_read_in_the_order_asked_for():
    links = [connection("c", "link", {"DC": ["1", "2"], "E3": ["2", "3"]})]
    assert link_floors("E3", "DC", links) == [[2, 1], [3, 2]]
    assert link_floors("E3", "MC", links) is None


def test_lines_are_cut_at_shared_vertices_only():
    graph = Graph(FRAME)
    a, b, c, d = (0.0, 0.0), (1.0, 0.0), (2.0, 0.0), (1.0, 1.0)
    graph.add_lines([([a, b, c], {"kind": "outdoor"}), ([b, d], {"kind": "outdoor"})])
    assert sorted((len(e.points), graph.nodes[e.a], graph.nodes[e.b]) for e in graph.edges) == [(2, a, b), (2, b, d), (2, b, c)]
    # A line that merely crosses another isn't joined to it.
    graph = Graph(FRAME)
    graph.add_lines([([(0.0, 0.0), (2.0, 0.0)], {"kind": "outdoor"}), ([(1.0, -1.0), (1.0, 1.0)], {"kind": "outdoor"})])
    assert len(graph.edges) == 2 and len(graph.nodes) == 4


def test_splitting_an_edge_keeps_its_shape_and_length():
    graph = Graph(FRAME)
    corner = tuple(at(50, 0))
    graph.add_lines([([tuple(at(0, 0)), corner, tuple(at(50, 50))], {"kind": "corridor", "building": "MC"})])
    before = true_length(graph.edges[0].points, 43.47)
    first, second, start = graph.split([(0, 30.0), (0, 70.0), (0, 0.0)])
    assert start == graph.edges[0].a
    assert len(graph.edges) == 3
    assert abs(sum(true_length(e.points, 43.47) for e in graph.edges) - before) < 1e-3
    assert corner in [p for e in graph.edges for p in e.points]
    assert {first, second} <= {n for e in graph.edges for n in (e.a, e.b)}
    assert all(e.building == "MC" for e in graph.edges)


def test_a_corridor_crossing_a_wall_gets_a_link_with_the_floors():
    graph, _, issues = compile_graph(
        [building("A", 0, 0, 50, 50), building("B", 50, 0, 100, 50)],
        connections=[connection("c", "link", {"A": ["1"], "B": ["2"]})],
        corridors=[[(10, 25), (90, 25)]],
        footpaths=[footpath((0, 60), (100, 60))],
        doors=[door("A-door", "A", 10, 50)],
    )
    assert issues == []
    [link] = edges_of(graph, "link")
    assert link["length"] == 0 and link["floors"] in ([[1, 2]], [[2, 1]])
    assert {e["building"] for e in edges_of(graph, "corridor")} == {"A", "B"}


def test_a_wall_with_no_link_in_the_data_is_reported():
    _, _, issues = compile_graph(
        [building("A", 0, 0, 50, 50), building("B", 50, 0, 100, 50)],
        corridors=[[(10, 25), (90, 25)]],
        footpaths=[footpath((0, 60), (100, 60))],
        doors=[door("A-door", "A", 10, 50)],
    )
    assert [i.message for i in issues] == ["graph: lines join A and B, which no connection links"]


def test_a_door_joins_its_corridor_and_the_footpath():
    graph, notes, _ = compile_graph(
        [building("MC", 0, 0, 100, 50)],
        doors=[door("MC-door", "MC", 30, 50)],
        corridors=[[(10, 25), (90, 25)]],
        footpaths=[footpath((0, 70), (100, 70))],
    )
    assert notes["noWayIn"] == [] and notes["noWayOut"] == []
    node = graph["doors"]["MC-door"]
    [stub] = edges_of(graph, "door")
    assert stub["b"] == node and stub["floors"] == [[None, None]] and not stub.get("oneWay")
    assert any(node in (e["a"], e["b"]) for e in edges_of(graph, "outdoor"))
    # The corridor and the footpath were each split where the door joins them.
    assert len(edges_of(graph, "corridor")) == 3  # door, and the building's own arrival point
    assert len(edges_of(graph, "outdoor")) == 3


def test_an_exit_only_door_lets_people_out_but_not_in():
    graph, _, _ = compile_graph(
        [building("MC", 0, 0, 100, 50)],
        doors=[door("MC-door", "MC", 30, 50, kind="exit")],
        corridors=[[(10, 25), (90, 25)]],
        footpaths=[footpath((0, 70), (100, 70))],
    )
    [stub] = edges_of(graph, "door")
    assert stub["oneWay"] is True and stub["b"] == graph["doors"]["MC-door"]


def test_only_a_surveyed_door_says_what_floor_it_is_on():
    def floors(verified):
        graph, _, _ = compile_graph(
            [building("MC", 0, 0, 100, 50)],
            doors=[door("MC-door", "MC", 30, 50, level="2", verified=verified)],
            corridors=[[(10, 25), (90, 25)]],
            footpaths=[footpath((0, 70), (100, 70))],
        )
        return edges_of(graph, "door")[0]["floors"]

    assert floors(True) == [[2, None]]
    assert floors(False) == [[None, None]]


def test_a_door_wont_join_a_footpath_through_a_building():
    graph, notes, _ = compile_graph(
        [building("A", 0, 0, 100, 50), building("B", 0, 55, 100, 90)],
        doors=[door("A-door", "A", 30, 50), door("B-door", "B", 30, 90)],
        corridors=[[(10, 25), (90, 25)]],
        footpaths=[footpath((0, 100), (100, 100))],
    )
    assert notes["noWayOut"] == ["A-door"]


def test_a_door_with_no_other_way_joins_the_nearest_footpath_regardless():
    graph, notes, _ = compile_graph(
        [building("A", 0, 0, 100, 50), building("B", 0, 55, 100, 90)],
        doors=[door("A-door", "A", 30, 50), door("B-door", "B", 30, 90)],
        footpaths=[footpath((0, 100), (100, 100))],
    )
    assert notes["noWayOut"] == ["A-door"]
    assert notes["cutOff"] == []
    assert set(graph["doors"]) == {"A-door", "B-door"}


def test_a_stub_stays_inside_its_building():
    # An L: the door is on the far arm, and a straight line to the corridor would cross the notch.
    outline = [at(0, 0), at(100, 0), at(100, 20), at(20, 20), at(20, 100), at(0, 100), at(0, 0)]
    shape = {"code": "L", "parts": [{"outline": outline, "holes": []}]}
    _, notes, _ = compile_graph(
        [shape],
        doors=[door("L-door", "L", 20, 90)],
        corridors=[[(90, 10), (60, 10)]],
        footpaths=[footpath((30, 90), (30, 110))],
    )
    assert notes["noWayIn"] == ["L-door"]


def test_a_building_with_lines_has_one_arrival_point_on_them():
    graph, _, _ = compile_graph(
        [building("MC", 0, 0, 100, 50, label=at(50, 40))],
        doors=[door("MC-door", "MC", 30, 50)],
        corridors=[[(10, 25), (90, 25)]],
        footpaths=[footpath((0, 70), (100, 70))],
    )
    entry = graph["buildings"]["MC"]
    assert entry["hasLines"] is True and len(entry["anchors"]) == 1
    lon, lat = graph["nodes"][entry["anchors"][0]]
    assert abs(FRAME.to_meters([lon, lat])[0] - 50) < 0.01


def test_a_building_without_lines_is_reached_at_its_doors():
    graph, notes, _ = compile_graph(
        [building("DP", 0, 0, 100, 50)],
        doors=[door("DP-a", "DP", 30, 50), door("DP-b", "DP", 70, 50)],
        footpaths=[footpath((0, 70), (100, 70))],
    )
    assert notes["noLines"] == ["DP"]
    entry = graph["buildings"]["DP"]
    assert entry["hasLines"] is False
    assert sorted(entry["anchors"]) == sorted(graph["doors"].values())


def test_a_line_reaching_a_building_with_none_of_its_own_arrives_there():
    graph, _, _ = compile_graph(
        [building("SLC", 0, 0, 50, 50), building("PAC", 50, 0, 100, 50)],
        doors=[door("SLC-door", "SLC", 30, 50), door("PAC-door", "PAC", 70, 50)],
        corridors=[[(10, 25), (49.8, 25)]],
        footpaths=[footpath((0, 70), (100, 70))],
    )
    assert len(graph["buildings"]["PAC"]["anchors"]) == 2


def test_a_building_with_no_doors_or_lines_is_reached_by_the_nearest_footpath():
    graph, _, _ = compile_graph([building("LHI", 0, 0, 100, 50)], footpaths=[footpath((0, 70), (100, 70))])
    assert len(graph["buildings"]["LHI"]["anchors"]) == 1


def test_closed_connections_arent_routed():
    bridge = connection("c", "bridge", {"A": ["1"], "B": ["1"]}, paths=[{"points": [at(50, 25), at(60, 25)], "from": 0, "to": 1}], closed=True)
    graph, _, _ = compile_graph(
        [building("A", 0, 0, 50, 50), building("B", 60, 0, 100, 50)],
        connections=[bridge],
        doors=[door("A-door", "A", 30, 50)],
        corridors=[[(10, 25), (50, 25)], [(60, 25), (90, 25)]],
        footpaths=[footpath((0, 70), (100, 70))],
    )
    assert edges_of(graph, "bridge") == []


def test_a_bridge_cut_by_a_junction_keeps_the_floors_of_its_ends():
    tunnel = connection(
        "t", "tunnel", {"A": ["1"], "B": ["B"], "C": ["2"]},
        paths=[
            {"points": [at(50, 25), at(75, 25), at(100, 25)], "from": 0, "to": 2},
            {"points": [at(75, 25), at(75, 60)], "from": None, "to": 1},
        ],
    )
    graph, _, _ = compile_graph(
        [building("A", 0, 0, 50, 50), building("B", 50, 60, 100, 100), building("C", 100, 0, 150, 50)],
        connections=[tunnel],
        doors=[door("A-door", "A", 30, 50)],
        corridors=[[(10, 25), (50, 25)], [(75, 60), (75, 90)], [(100, 25), (140, 25)]],
        footpaths=[footpath((0, 110), (150, 110))],
    )
    assert sorted(e["floors"] for e in edges_of(graph, "tunnel")) == [[[1, 0]], [[1, 1]], [[1, 2]]]


def test_islands_of_footpath_are_dropped():
    graph, _, _ = compile_graph(
        [building("MC", 0, 0, 100, 50)],
        doors=[door("MC-door", "MC", 30, 50)],
        footpaths=[footpath((0, 70), (100, 70), (200, 70)), footpath((500, 500), (510, 500))],
    )
    assert max(FRAME.to_meters(n)[0] for n in graph["nodes"]) < 300


def test_node_numbers_are_valid_after_renumbering():
    graph, _, _ = compile_graph(
        [building("MC", 0, 0, 100, 50)],
        doors=[door("MC-door", "MC", 30, 50)],
        corridors=[[(10, 25), (90, 25)]],
        footpaths=[footpath((0, 70), (100, 70)), footpath((500, 500), (510, 500))],
    )
    count = len(graph["nodes"])
    assert all(0 <= e["a"] < count and 0 <= e["b"] < count for e in graph["edges"])
    assert all(0 <= n < count for n in graph["doors"].values())
    assert not math.isnan(sum(e["length"] for e in graph["edges"]))
