from connections import apply_overrides, base_connections

CODES = {"AL", "TC", "E5", "E6", "DC", "EIT", "MC", "SLC", "B2", "QNC", "E3"}


def feature(connection_id, buildings, kind, **extra):
    return {
        "properties": {"id": connection_id, "buildings": buildings, "kind": kind, **extra},
        "geometry": {"coordinates": [[[0, 0], [1, 1]]]},
    }


def errors(issues):
    return [i.message for i in issues if i.severity == "error"]


def test_defaults_give_unnamed_connections_a_readable_name_and_unknown_floors():
    issues = []
    [tunnel, bridge] = apply_overrides(
        base_connections([feature("conn-w1", ["AL", "TC"], "tunnel"), feature("conn-w2", ["E5", "E6"], "bridge", name="E6 Bridge")]),
        {},
        CODES,
        issues,
    )
    assert errors(issues) == []
    assert (tunnel["name"], tunnel["verified"], tunnel["buildings"]) == ("AL–TC tunnel", False, ["AL", "TC"])
    assert tunnel["ends"] == [{"building": "AL", "floors": []}, {"building": "TC", "floors": []}]
    assert bridge["name"] == "E6 Bridge"


def test_overrides_set_floors_close_and_hide():
    issues = []
    connections = apply_overrides(
        base_connections([feature("conn-w1", ["DC", "EIT"], "bridge"), feature("conn-w2", ["MC", "SLC"], "bridge")]),
        {"connections": {"conn-w1": {"ends": {"EIT": ["3"], "DC": ["2", "3"]}, "verified": True, "closed": True}, "conn-w2": {"hidden": True}}},
        CODES,
        issues,
    )
    assert errors(issues) == []
    [bridge] = connections
    assert (bridge["id"], bridge["verified"], bridge["closed"], bridge["buildings"]) == ("conn-w1", True, True, ["EIT", "DC"])
    assert bridge["ends"] == [{"building": "EIT", "floors": ["3"]}, {"building": "DC", "floors": ["2", "3"]}]


def test_ends_replace_the_buildings_osm_found():
    [link] = apply_overrides(
        base_connections([feature("conn-w1", ["DC", "EIT", "E3"], "bridge")]),
        {"connections": {"conn-w1": {"kind": "link", "ends": {"DC": ["2"], "E3": ["3"]}}}},
        CODES,
        [],
    )
    assert (link["kind"], link["buildings"], link["name"]) == ("link", ["DC", "E3"], "DC–E3 link")


def test_added_connections_need_ends_and_get_their_lines_elsewhere():
    issues = []
    connections = apply_overrides(
        [],
        {"added": [
            {"id": "conn-tc-sch", "kind": "tunnel", "ends": {"TC": ["0"], "AL": ["1"]}, "verified": True},
            {"id": "conn-bad", "kind": "bridge"},
        ]},
        CODES,
        issues,
    )
    assert [c["id"] for c in connections] == ["conn-tc-sch"]
    assert connections[0]["paths"] == [] and connections[0]["verified"] is True
    assert any("conn-bad needs ends" in m for m in errors(issues))


def test_a_bridge_inside_one_building_has_one_end():
    [bridge] = apply_overrides([], {"added": [{"id": "conn-dc-bridge", "kind": "bridge", "ends": {"DC": ["2", "3"]}}]}, CODES, [])
    assert (bridge["buildings"], bridge["name"]) == (["DC"], "DC bridge")


def test_unknown_ids_fields_buildings_and_floor_types_are_errors():
    issues = []
    apply_overrides(
        base_connections([feature("conn-w1", ["MC", "SLC"], "bridge")]),
        {"connections": {"conn-w9": {}, "conn-w1": {"elevation": 2, "ends": {"XX": ["1"], "MC": [3]}}}},
        CODES,
        issues,
    )
    messages = errors(issues)
    assert any("no connection conn-w9" in m for m in messages)
    assert any("unknown field 'elevation'" in m for m in messages)
    assert any("unknown building XX" in m for m in messages)
    assert any("floors for MC must be a list of strings" in m for m in messages)
