from compile import build_buildings, validate


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


def test_inventory_level_override_wins():
    building = build_buildings([entry("LIB", levels=10)], [outline("LIB", levels=2)], 4.0)[0]
    assert building["parts"][0]["levels"] == 10
    assert building["levelsEstimated"] is False
