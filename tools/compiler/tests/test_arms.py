from arms import LocalFrame, remove_bridge_arms
from shapely.geometry import Polygon

ORIGIN = {"latitude": 43.47, "longitude": -80.54}
FRAME = LocalFrame(ORIGIN)


def lonlat(points):
    return [FRAME.to_lonlat(p) for p in points]


# A 40 m square with a 4 m wide, 20 m long arm off its east side.
SQUARE_WITH_ARM = [(0, 0), (40, 0), (40, 18), (60, 18), (60, 22), (40, 22), (40, 40), (0, 40), (0, 0)]


def building(code="E3", ring=SQUARE_WITH_ARM):
    return {"code": code, "parts": [{"osmId": "way/1", "outline": lonlat(ring), "holes": []}]}


def connection(kind="bridge", points=((42, 20), (60, 20)), buildings=("E3",)):
    return {"kind": kind, "buildings": list(buildings), "paths": [{"points": lonlat(points)}]}


def area(b):
    return sum(Polygon([FRAME.to_meters(p) for p in part["outline"]]).area for part in b["parts"])


def test_a_bridge_along_a_thin_arm_takes_the_arm_out_of_the_building():
    b = building()
    remove_bridge_arms([b], [connection()], FRAME)
    assert abs(area(b) - 1600) < 5  # the square, without the 80 m² arm


def test_the_body_keeps_its_id_and_a_building_without_an_arm_is_left_alone():
    b = building()
    plain = building("MC", [(100, 0), (140, 0), (140, 40), (100, 40), (100, 0)])
    outline = plain["parts"][0]["outline"]
    remove_bridge_arms([b, plain], [connection(buildings=("E3", "MC"))], FRAME)
    assert b["parts"][0]["osmId"] == "way/1"
    assert plain["parts"][0]["outline"] == outline


def test_tunnels_and_undrawn_bridges_keep_the_outline():
    for walkway in (connection(kind="tunnel"), {**connection(), "paths": []}):
        b = building()
        remove_bridge_arms([b], [walkway], FRAME)
        assert abs(area(b) - 1680) < 5


def test_a_bridge_that_only_clips_an_arm_leaves_it():
    b = building()
    remove_bridge_arms([b], [connection(points=((50, 19.5), (50, 20.5)))], FRAME)
    assert abs(area(b) - 1680) < 5
