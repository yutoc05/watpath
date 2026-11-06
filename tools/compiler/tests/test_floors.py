import pytest

from floors import floor_names, ordinal, title


def test_ordinals_place_special_floors_between_numbered_ones():
    assert [ordinal(n) for n in ["B", "MB", "LL", "C", "M", "1", "2M", "7"]] == [0, 0.5, 0, 0, 0.5, 1, 2.5, 7]
    assert ordinal("P") > ordinal("99")  # the penthouse is above every numbered floor
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
