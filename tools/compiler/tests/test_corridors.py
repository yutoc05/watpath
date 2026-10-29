from shapely.geometry import LineString, Point, Polygon, box

from corridors import CORRIDOR_WIDTH, LocalFrame, add_corridors, corridor_geometry

OUTLINE = box(0, 0, 100, 60)


def test_a_corridor_is_the_hallway_widened_with_walls_down_both_sides_and_open_ends():
    area, walls = corridor_geometry([LineString([(10, 30), (90, 30)])], OUTLINE)
    assert abs(area.area - 80 * CORRIDOR_WIDTH) < 0.5
    # Two long walls, nothing across the ends (where a door or bridge would be).
    assert abs(walls.length - 2 * 80) < 2
    assert walls.distance(Point(10, 30)) > CORRIDOR_WIDTH / 2 - 0.01
    assert walls.distance(Point(90, 30)) > CORRIDOR_WIDTH / 2 - 0.01


def test_junctions_merge_without_walls_across_them():
    through = LineString([(10, 30), (90, 30)])
    branch = LineString([(50, 30), (50, 55)])
    area, walls = corridor_geometry([through, branch], OUTLINE)
    # Walking from the main corridor into the branch never crosses a wall.
    assert not walls.intersects(LineString([(50, 30), (50, 40)]))
    assert area.contains(Point(50, 40))


def test_hallways_meeting_end_to_end_have_no_notch_at_the_corner():
    area, walls = corridor_geometry([LineString([(10, 30), (50, 30)]), LineString([(50, 30), (50, 55)])], OUTLINE)
    corner = Point(50 + CORRIDOR_WIDTH / 2 - 0.1, 30 - CORRIDOR_WIDTH / 2 + 0.1)
    assert area.contains(corner)


def test_corridors_stop_at_the_outline_and_leave_it_unwalled():
    area, walls = corridor_geometry([LineString([(50, 30), (50, 80)])], OUTLINE)
    assert area.bounds[3] <= 60.5 + 1e-6
    assert walls.distance(Point(50, 60)) > CORRIDOR_WIDTH / 2 - 0.01  # the building's own wall is there


def test_add_corridors_puts_each_drawn_floor_on_that_floor_only():
    frame = LocalFrame({"latitude": 43.472, "longitude": -80.544})
    ring = [frame.to_lonlat(p) for p in [(0, 0), (100, 0), (100, 60), (0, 60), (0, 0)]]
    dc = {"code": "DC", "parts": [{"outline": ring}], "floors": [{"name": "1", "elevation": 0.0}, {"name": "2", "elevation": 4.0}]}

    def drawn(floor, *lines):
        coordinates = [[frame.to_lonlat(p) for p in line] for line in lines]
        return {"properties": {"building": "DC", "floor": floor}, "geometry": {"type": "MultiLineString", "coordinates": coordinates}}

    issues = []
    add_corridors([dc], [drawn("2", [(20, 30), (80, 30)], [(50, 30), (50, 55)])], frame, issues)
    assert issues == []
    assert "corridor" in dc["floors"][1] and "corridor" not in dc["floors"][0]
    triangle = dc["floors"][1]["corridor"]["triangles"][0]
    assert len(triangle) == 3 and all(len(p) == 2 for p in triangle)

    add_corridors([dc], [drawn("7", [(20, 30), (80, 30)]), {"properties": {"building": "XX", "floor": "1"}, "geometry": {"type": "LineString", "coordinates": []}}], frame, issues)
    assert any("DC has no floor '7'" in i.message for i in issues)
    assert any("unknown building 'XX'" in i.message for i in issues)
