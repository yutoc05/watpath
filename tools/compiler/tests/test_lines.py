from arms import LocalFrame
from lines import attach_lines, check_corridors_inside, check_lines_meet


def line(kind, points=((0, 0), (1, 1)), **properties):
    return {"properties": {"kind": kind, **properties}, "geometry": {"coordinates": [list(p) for p in points]}}


def connection(connection_id, kind, *buildings):
    return {"id": connection_id, "kind": kind, "ends": [{"building": code, "floors": ["1"]} for code in buildings], "paths": []}


def errors(issues):
    return [i.message for i in issues if i.severity == "error"]


def test_corridors_are_just_lines():
    issues = []
    assert attach_lines([], [line("corridor", [(0, 0), (1, 0), (1, 1)])], issues) == [[[0, 0], [1, 0], [1, 1]]]
    assert issues == []


def test_a_bridge_gets_its_line_with_the_end_at_each_tip():
    bridge = connection("c", "bridge", "MC", "QNC")
    assert attach_lines([bridge], [line("bridge", connection="c", **{"from": "QNC", "to": "MC"})], issues := []) == []
    assert issues == []
    assert bridge["paths"] == [{"points": [[0, 0], [1, 1]], "from": 1, "to": 0}]


def test_a_t_shaped_tunnel_has_a_junction_end_and_a_bridge_inside_one_building_has_the_same_end_twice():
    tunnel = connection("t", "tunnel", "ML", "AL", "EV1")
    inside = connection("b", "bridge", "DC")
    attach_lines([tunnel, inside], [
        line("tunnel", connection="t", **{"from": "ML", "to": "EV1"}),
        line("tunnel", connection="t", **{"from": None, "to": "AL"}),
        line("bridge", connection="b", **{"from": "DC", "to": "DC"}),
    ], issues := [])
    assert issues == []
    assert [(p["from"], p["to"]) for p in tunnel["paths"]] == [(0, 2), (None, 1)]
    assert [(p["from"], p["to"]) for p in inside["paths"]] == [(0, 0)]


def test_a_connection_with_no_line_stays_undrawn():
    bridge = connection("c", "bridge", "MC", "QNC")
    attach_lines([bridge], [], issues := [])
    assert issues == [] and bridge["paths"] == []


def test_bad_lines_are_errors():
    bridge = connection("c", "bridge", "MC", "QNC")
    bad = [
        line("wall"),
        line("corridor", [(0, 0)]),
        line("corridor", connection="c"),
        line("bridge", connection="nope"),
        line("tunnel", connection="c"),
        line("bridge", connection="c", **{"from": "DC", "to": "MC"}),
    ]
    attach_lines([bridge], bad, issues := [])
    messages = errors(issues)
    assert len(messages) == len(bad)
    assert "unknown kind 'wall'" in messages[0]
    assert "two points" in messages[1]
    assert "corridor doesn't belong" in messages[2]
    assert "no connection 'nope'" in messages[3]
    assert "is a bridge, not a tunnel" in messages[4]
    assert "doesn't reach DC" in messages[5]
    assert bridge["paths"] == []


FRAME = LocalFrame({"latitude": 43.47, "longitude": -80.54})


def square(x0, x1):
    ring = [FRAME.to_lonlat(p) for p in [(x0, 0), (x1, 0), (x1, 40), (x0, 40), (x0, 0)]]
    return {"parts": [{"outline": ring, "holes": []}]}


def corridor(*points):
    return [FRAME.to_lonlat(p) for p in points]


def test_a_corridor_inside_buildings_passes_even_across_touching_ones():
    check_corridors_inside([corridor((5, 20), (75, 20))], [square(0, 40), square(40, 80)], FRAME, issues := [])
    assert issues == []


def test_a_corridor_that_leaves_the_buildings_is_an_error():
    check_corridors_inside([corridor((5, 20), (55, 20))], [square(0, 40)], FRAME, issues := [])
    assert any("runs 15.0 m outside" in m for m in errors(issues))


def test_a_corridor_may_touch_a_wall():
    check_corridors_inside([corridor((5, 20), (40.2, 20))], [square(0, 40)], FRAME, issues := [])
    assert issues == []


def geo(*points):
    return {"geometry": {"coordinates": [list(p) for p in points]}}


def test_lines_that_share_a_vertex_meet():
    frame = LocalFrame({"latitude": 43.47, "longitude": -80.54})
    a, b, c = frame.to_lonlat((0, 0)), frame.to_lonlat((50, 0)), frame.to_lonlat((50, 50))
    check_lines_meet([geo(a, b, c), geo(b, frame.to_lonlat((100, 0)))], frame, issues := [])
    assert issues == []


def test_a_line_that_stops_just_short_of_another_is_an_error():
    frame = LocalFrame({"latitude": 43.47, "longitude": -80.54})
    a, b = frame.to_lonlat((0, 0)), frame.to_lonlat((100, 0))
    check_lines_meet([geo(a, b), geo(frame.to_lonlat((50, 0.2)), frame.to_lonlat((50, 50)))], frame, issues := [])
    assert any("stops short" in m for m in errors(issues))


def test_lines_that_end_apart_are_fine():
    frame = LocalFrame({"latitude": 43.47, "longitude": -80.54})
    check_lines_meet([geo(frame.to_lonlat((0, 0)), frame.to_lonlat((100, 0))), geo(frame.to_lonlat((50, 5)), frame.to_lonlat((50, 50)))], frame, issues := [])
    assert issues == []
