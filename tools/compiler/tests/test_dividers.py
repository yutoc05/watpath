from arms import LocalFrame
from dividers import dividers

FRAME = LocalFrame({"latitude": 43.47, "longitude": -80.54})


def building(x0, x1, y0=0, y1=40):
    ring = [FRAME.to_lonlat(p) for p in [(x0, y0), (x1, y0), (x1, y1), (x0, y1), (x0, y0)]]
    return {"parts": [{"outline": ring, "holes": []}]}


def lengths(buildings):
    result = []
    for line in dividers(buildings, FRAME):
        points = [FRAME.to_meters(p) for p in line]
        result.append(sum(((a[0] - b[0]) ** 2 + (a[1] - b[1]) ** 2) ** 0.5 for a, b in zip(points, points[1:])))
    return result


def test_buildings_that_touch_get_a_line_along_their_shared_wall():
    [length] = lengths([building(0, 40), building(40, 80, 10, 30)])
    assert abs(length - 20) < 1


def test_a_small_gap_still_counts_as_touching():
    assert len(lengths([building(0, 40), building(40.2, 80)])) >= 1


def test_buildings_apart_have_no_line():
    assert lengths([building(0, 40), building(60, 80)]) == []


def test_overlapping_buildings_have_no_line_through_them():
    assert lengths([building(0, 40), building(20, 60)]) == []


def test_buildings_meeting_at_a_corner_have_no_line():
    assert lengths([building(0, 40), building(40, 80, 40, 80)]) == []
