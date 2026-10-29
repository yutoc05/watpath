from compile import assign_floors, build_buildings, floor_summary, validate


def entry(code, aliases=(), **extra):
    return {"code": code, "name": code, "aliases": list(aliases), "group": "core", "priority": 1, **extra}


def outline(code, levels=3):
    ring = [[0, 0], [1, 0], [1, 1], [0, 0]]
    return {"properties": {"code": code, "osmId": f"way/{code}", "levels": levels}, "geometry": {"coordinates": [ring]}}


def errors(issues):
    return [i.message for i in issues if i.severity == "error"]


def test_valid_inventory_has_no_errors():
    assert errors(validate([entry("MC"), entry("DC")], [outline("MC"), outline("DC")])) == []


def test_alias_colliding_with_another_code_is_an_error():
    issues = validate([entry("MC"), entry("DC", aliases=["mc"])], [outline("MC"), outline("DC")])
    assert any("already used by MC" in m for m in errors(issues))


def test_building_without_outline_is_an_error():
    assert any("no outline" in m for m in errors(validate([entry("MC")], [])))


def test_outline_without_inventory_entry_is_an_error():
    assert any("no inventory entry" in m for m in errors(validate([], [outline("MC")])))


def test_unknown_levels_are_estimated_with_a_warning():
    issues = validate([entry("MC")], [outline("MC", levels=None)])
    assert errors(issues) == []
    assert any(i.severity == "warning" for i in issues)
    building = build_buildings([entry("MC")], [outline("MC", levels=None)], 4.0)[0]
    assert building["levelsEstimated"] is True
    assert building["parts"][0]["levels"] == 2


def test_inventory_level_override_wins_but_only_an_official_floor_list_makes_floors_known():
    building = build_buildings([entry("LIB", levels=10)], [outline("LIB", levels=2)], 4.0)[0]
    assert building["parts"][0]["levels"] == 10
    assert building["levelsEstimated"] is True
    official = build_buildings([entry("LIB", floors=["B", "1", "2"])], [outline("LIB", levels=2)], 4.0)[0]
    assert official["levelsEstimated"] is False


def test_label_overrides_must_be_coordinates_inside_the_building():
    inside = validate([entry("E2", label=[0.5, 0.25])], [outline("E2")])
    assert errors(inside) == [] and not any("label" in i.message for i in inside)
    outside = validate([entry("E2", label=[5, 5])], [outline("E2")])
    assert any("label is outside" in i.message for i in outside)
    assert any("label must be" in m for m in errors(validate([entry("E2", label="middle")], [outline("E2")])))
    building = build_buildings([entry("E2", label=[0.5, 0.25])], [outline("E2")], 4.0)[0]
    assert building["label"] == [0.5, 0.25]


def test_only_floors_a_connection_meets_are_on_the_map_and_buildings_start_on_the_busiest():
    mc = build_buildings([entry("MC", floors=["B", "1", "2", "3", "P"])], [outline("MC")], 4.0)[0]
    qnc, slc, c2 = (build_buildings([entry(code)], [outline(code)], 4.0)[0] for code in ["QNC", "SLC", "C2"])

    def link(a, fa, b, fb):
        return {"id": f"{a}-{b}", "ends": [{"building": a, "floors": fa}, {"building": b, "floors": fb}]}

    issues = []
    links = [link("MC", ["3"], "QNC", ["2"]), link("MC", ["3"], "SLC", ["2"]), link("MC", ["1"], "C2", ["B"])]
    assign_floors([mc, qnc, slc, c2], links, issues)
    assert issues == []
    assert [(f["name"], f["mapped"]) for f in mc["floors"]] == [("B", False), ("1", True), ("2", False), ("3", True), ("P", False)]
    assert mc["defaultFloor"] == "3"  # two connections meet floor 3, one meets floor 1
    assert mc["levelsEstimated"] is False and qnc["levelsEstimated"] is True
    assert [f["title"] for f in mc["floors"]][::4] == ["Basement", "Penthouse"]


def test_buildings_no_connection_meets_have_no_map_floors():
    erc = build_buildings([entry("ERC", floors=["1", "2", "3"])], [outline("ERC")], 4.0)[0]
    assign_floors([erc], [], [])
    assert not any(f["mapped"] for f in erc["floors"]) and "defaultFloor" not in erc


def test_floor_summary_shortens_runs_of_numbered_floors():
    def floors(*names):
        return {"floors": [{"name": n, "title": {"B": "Basement", "P": "Penthouse", "2M": "2nd floor mezzanine"}.get(n, n)} for n in names]}
    assert floor_summary(floors("B", "1", "2", "3", "4", "5", "6", "P")) == "Basement, 1–6, Penthouse"
    assert floor_summary(floors("1", "2", "2M", "3", "4")) == "1–2, 2nd floor mezzanine, 3–4"
    assert floor_summary(floors("1")) == "1"
