import pytest

from floors import floor_names, ordinal, solve_ground_elevations, title


def building(code, height=4.0):
    return {"code": code, "levelHeight": height}


def connection(connection_id, **ends):
    return {"id": connection_id, "ends": [{"building": code, "floors": floors} for code, floors in ends.items()]}


def test_ordinals_place_special_floors_between_numbered_ones():
    assert [ordinal(n) for n in ["B", "MB", "LL", "C", "M", "1", "2M", "7"]] == [0, 0.5, 0, 0, 0.5, 1, 2.5, 7]
    assert ordinal("P", top=6) == 7  # the penthouse is above the top floor
    with pytest.raises(ValueError):
        ordinal("X")


def test_titles_spell_floors_out():
    assert [title(n) for n in ["B", "3", "2M", "P", "C"]] == ["Basement", "Floor 3", "2nd floor mezzanine", "Penthouse", "Concourse"]


def test_estimated_floors_cover_levels_and_every_floor_a_connection_reaches():
    issues = []
    assert floor_names(3, {"B", "4"}, "C2", issues) == ["B", "1", "2", "3", "4"]
    assert floor_names(2, set(), "ERC", issues) == ["1", "2"]
    assert issues == []


def test_official_floors_are_used_as_given_and_must_include_every_connection_floor():
    issues = []
    assert floor_names(2, {"1", "3"}, "MC", issues, ["B", "1", "2", "3", "P"]) == ["B", "1", "2", "3", "P"]
    assert issues == []
    floor_names(2, {"9"}, "MC", issues, ["B", "1", "2"])
    assert any("meets floor '9'" in i.message for i in issues)


def test_ground_heights_follow_the_floors_connections_meet():
    buildings = [building("MC"), building("QNC"), building("C2"), building("ERC")]
    connections = [connection("a", MC=["3"], QNC=["2"]), connection("b", MC=["1"], C2=["B"])]
    ground = solve_ground_elevations(buildings, connections, issues := [])
    assert issues == []
    # MC floor 3 = QNC floor 2, so QNC sits a floor (4 m) above MC; C2's basement = MC floor 1, so C2 sits a floor above too.
    assert ground["QNC"] - ground["MC"] == pytest.approx(4, abs=0.05)
    assert ground["C2"] - ground["MC"] == pytest.approx(4, abs=0.05)
    assert ground["ERC"] == 0  # unconnected buildings stay at ground level
    assert abs(sum(ground[c] for c in ["MC", "QNC", "C2"])) < 0.05  # and connected ones average to it


def test_floors_that_disagree_around_a_loop_are_reported():
    buildings = [building("A"), building("B"), building("C")]
    connections = [connection("ab", A=["1"], B=["1"]), connection("bc", B=["1"], C=["1"]), connection("ca", C=["2"], A=["1"])]
    issues = []
    solve_ground_elevations(buildings, connections, issues)
    assert any("off by" in i.message for i in issues)
