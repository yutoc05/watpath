from lines import attach_lines


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
