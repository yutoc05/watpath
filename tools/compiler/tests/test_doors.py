from doors import apply_overrides, assign_names, attach_photos, base_doors


def entrance(code, node, lon, lat, kind="yes", **tags):
    return {
        "properties": {"code": code, "osmId": f"node/{node}", "entrance": kind, **tags},
        "geometry": {"coordinates": [lon, lat]},
    }


def errors(issues):
    return [i.message for i in issues if i.severity == "error"]


def test_base_doors_map_osm_tags():
    [door] = base_doors([entrance("MC", 42, -80.5, 43.4, kind="main", wheelchair="yes", level="1")])
    assert door["id"] == "MC-n42"
    assert (door["kind"], door["accessible"], door["level"], door["verified"]) == ("main", True, "1", False)


def test_names_use_direction_from_building_center_and_number_repeats():
    doors = base_doors([
        entrance("MC", 1, 0.0, 1.0, kind="main"),   # north
        entrance("MC", 2, 1.0, 0.0),                # east
        entrance("MC", 3, -0.2, -1.0),              # south, slightly west
        entrance("MC", 4, 0.2, -1.0),               # south, slightly east
    ])
    assign_names(doors, {"MC": (0.0, 0.0)})
    names = {d["id"]: d["name"] for d in doors}
    assert names["MC-n1"] == "North main entrance"
    assert names["MC-n2"] == "East entrance"
    # Repeats are numbered clockwise: the east-of-south door (bearing < 180°) comes first.
    assert (names["MC-n4"], names["MC-n3"]) == ("South entrance 1", "South entrance 2")


def test_overrides_rename_hide_and_add_doors():
    issues = []
    doors = apply_overrides(
        base_doors([entrance("MC", 1, 0, 1), entrance("MC", 2, 1, 0)]),
        {
            "doors": {"MC-n1": {"name": "Comfy lounge door", "verified": True}, "MC-n2": {"hidden": True}},
            "added": [{"id": "MC-west-ramp", "building": "MC", "coordinate": [-1, 0], "kind": "main"}],
        },
        {"MC"},
        issues,
    )
    assert errors(issues) == []
    assert [(d["id"], d["name"]) for d in doors] == [("MC-n1", "Comfy lounge door"), ("MC-west-ramp", None)]
    assert doors[0]["verified"] is True


def test_override_for_missing_door_or_unknown_field_is_an_error():
    issues = []
    apply_overrides(base_doors([entrance("MC", 1, 0, 1)]), {"doors": {"MC-n9": {}, "MC-n1": {"colour": "red"}}}, {"MC"}, issues)
    assert any("no door MC-n9" in m for m in errors(issues))
    assert any("unknown field 'colour'" in m for m in errors(issues))


def test_added_door_needs_a_known_building():
    issues = []
    apply_overrides([], {"added": [{"id": "XX-front", "building": "XX", "coordinate": [0, 0]}]}, {"MC"}, issues)
    assert any("unknown building" in m for m in errors(issues))


def test_photos_attach_by_folder_name(tmp_path):
    (tmp_path / "MC-n1").mkdir()
    (tmp_path / "MC-n1" / "outside.jpg").write_bytes(b"jpg")
    (tmp_path / "MC-n1" / "notes.txt").write_text("ignored")
    (tmp_path / "MC-n404").mkdir()
    doors = base_doors([entrance("MC", 1, 0, 1)])
    issues = []
    copies = attach_photos(doors, tmp_path, issues)
    assert doors[0]["photos"] == ["photos/MC-n1/outside.jpg"]
    assert [bundle_path for _, bundle_path in copies] == ["photos/MC-n1/outside.jpg"]
    assert any("MC-n404" in m for m in errors(issues))
