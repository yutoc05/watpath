from import_osm import (
    assemble_rings,
    build_connections,
    build_entrances,
    build_features,
    build_footpaths,
    element_polygons,
    is_footpath,
    signed_area,
)


def test_assemble_rings_joins_reversed_segments():
    a, b, c, d = (0, 0), (1, 0), (1, 1), (0, 1)
    rings = assemble_rings([[a, b, c], [a, d, c]])  # second segment runs the "wrong" way
    assert len(rings) == 1
    assert rings[0][0] == rings[0][-1]
    assert set(rings[0]) == {a, b, c, d}


def test_unclosed_segments_are_dropped():
    assert assemble_rings([[(0, 0), (1, 0), (1, 1)]]) == []


def test_multipolygon_outer_is_ccw_and_hole_is_cw():
    outer = [{"lon": x, "lat": y} for x, y in [(0, 0), (0, 10), (10, 10), (10, 0), (0, 0)]]  # clockwise
    hole = [{"lon": x, "lat": y} for x, y in [(4, 4), (6, 4), (6, 6), (4, 6), (4, 4)]]  # counter-clockwise
    relation = {
        "type": "relation",
        "members": [
            {"type": "way", "role": "outer", "geometry": outer},
            {"type": "way", "role": "inner", "geometry": hole},
        ],
    }
    [polygon] = element_polygons(relation)
    assert signed_area(polygon[0]) > 0
    assert signed_area(polygon[1]) < 0


def test_build_features_matches_by_ref_and_name_and_skips_building_relations():
    square = [{"lon": x, "lat": y} for x, y in [(0, 0), (1, 0), (1, 1), (0, 0)]]
    elements = [
        {"type": "way", "id": 1, "tags": {"building": "university", "ref": "MC", "building:levels": "7"}, "geometry": square},
        {"type": "relation", "id": 2, "tags": {"building": "university", "ref": "MC", "type": "building"}, "members": []},
        {"type": "way", "id": 3, "tags": {"building": "university", "name": "Mathematics 3"}, "geometry": square},
        {"type": "way", "id": 4, "tags": {"building": "bridge", "ref": "MC"}, "geometry": square},
    ]
    inventory = [{"code": "MC", "osm": {"ref": "MC"}}, {"code": "M3", "osm": {"name": "Mathematics 3"}}, {"code": "XX", "osm": {"ref": "XX"}}]
    features, missing = build_features(inventory, elements)
    assert [(f["properties"]["code"], f["properties"]["osmId"]) for f in features] == [("M3", "way/3"), ("MC", "way/1")]
    assert features[1]["properties"]["levels"] == 7
    assert missing == ["XX"]


def test_entrances_snap_to_the_nearest_outline_and_skip_unusable_doors():
    # A ~100 m square building; 0.0009° of latitude is about 100 m.
    square = [[0.0, 0.0], [0.0013, 0.0], [0.0013, 0.0009], [0.0, 0.0009], [0.0, 0.0]]
    outlines = [{"properties": {"code": "MC"}, "geometry": {"coordinates": [square]}}]

    def node(node_id, lon, lat, **tags):
        return {"type": "node", "id": node_id, "lon": lon, "lat": lat, "tags": tags}

    elements = [
        node(1, 0.0005, 0.0, entrance="main", wheelchair="yes"),  # on the outline
        node(2, 0.0005, 0.00001, entrance="yes"),                 # ~1 m inside: snaps
        node(3, 0.0005, -0.0001, entrance="yes"),                 # ~11 m away: another building's door
        node(4, 0.0, 0.0004, entrance="emergency"),               # alarmed exit
        node(5, 0.0013, 0.0004, entrance="yes", access="private"),
        node(6, 0.0013, 0.0005, entrance="service"),              # loading dock
    ]
    entrances = build_entrances(elements, outlines)
    assert [e["properties"]["osmId"] for e in entrances] == ["node/1", "node/2"]
    assert entrances[0]["properties"] == {"code": "MC", "osmId": "node/1", "entrance": "main", "wheelchair": "yes"}


def test_connections_join_buildings_including_ones_that_share_a_wall():
    def box(code, x0, x1):
        ring = [[x0, 0.0], [x1, 0.0], [x1, 0.0009], [x0, 0.0009], [x0, 0.0]]
        return {"properties": {"code": code}, "geometry": {"coordinates": [ring]}}

    # A and B share a wall at x = 0.001; C stands 0.001° (~80 m) east of B.
    outlines = [box("A", 0.0, 0.001), box("B", 0.001, 0.002), box("C", 0.003, 0.004)]

    def way(way_id, coords, **tags):
        return {"type": "way", "id": way_id, "tags": tags, "geometry": [{"lon": x, "lat": y} for x, y in coords]}

    elements = [
        # Short bridge across the shared A/B wall.
        way(10, [(0.0009, 0.0004), (0.0011, 0.0004)], highway="footway", bridge="yes", layer="1"),
        # Tunnel from B to C in two pieces that share a node.
        way(21, [(0.0019, 0.0004), (0.0025, 0.0004)], highway="footway", tunnel="yes", layer="-1"),
        way(20, [(0.0025, 0.0004), (0.0031, 0.0004)], highway="footway", tunnel="yes", layer="-1"),
        # A corridor entirely inside A: not a connection.
        way(30, [(0.0002, 0.0002), (0.0008, 0.0002)], highway="corridor", indoor="yes"),
        # An outdoor sidewalk: not a candidate at all.
        way(40, [(0.0009, 0.0004), (0.0031, 0.0004)], highway="footway"),
    ]
    connections = build_connections(elements, outlines)
    summary = [(c["properties"]["buildings"], c["properties"]["kind"], c["properties"]["osmIds"]) for c in connections]
    assert summary == [(["A", "B"], "bridge", ["way/10"]), (["B", "C"], "tunnel", ["way/20", "way/21"])]


def test_an_outline_matching_either_ref_or_name_joins_the_building():
    square = [{"lon": x, "lat": y} for x, y in [(0, 0), (1, 0), (1, 1), (0, 0)]]
    elements = [
        {"type": "way", "id": 1, "tags": {"building": "yes", "ref": "CIF"}, "geometry": square},
        {"type": "way", "id": 2, "tags": {"building": "yes", "name": "Feridun Hamdullahpur Field House"}, "geometry": square},
    ]
    inventory = [{"code": "CIF", "osm": {"ref": "CIF", "name": "Feridun Hamdullahpur Field House"}}]
    features, missing = build_features(inventory, elements)
    assert [(f["properties"]["code"], f["properties"]["osmId"]) for f in features] == [("CIF", "way/1"), ("CIF", "way/2")]
    assert missing == []


def test_footpaths_are_outdoor_ways_open_to_pedestrians():
    assert is_footpath({"highway": "footway"})
    assert is_footpath({"highway": "service", "access": "private", "foot": "yes"})
    assert is_footpath({"highway": "footway", "tunnel": "building_passage"})
    assert not is_footpath({"highway": "footway", "indoor": "yes"})
    assert not is_footpath({"highway": "corridor"})
    assert not is_footpath({"highway": "service", "access": "private"})
    assert not is_footpath({"highway": "footway", "foot": "no"})
    assert not is_footpath({"highway": "secondary"})


def test_a_way_that_is_a_connection_is_not_also_a_footpath():
    way = [{"lon": 0.0, "lat": 0.0}, {"lon": 0.001, "lat": 0.0}]
    elements = [
        {"type": "way", "id": 2, "tags": {"highway": "steps"}, "geometry": way},
        {"type": "way", "id": 1, "tags": {"highway": "footway"}, "geometry": way},
        {"type": "way", "id": 3, "tags": {"highway": "footway", "bridge": "yes"}, "geometry": way},
    ]
    connections = [{"properties": {"osmIds": ["way/3"]}}]
    features = build_footpaths(elements, connections)
    assert [(f["properties"]["osmId"], f["properties"]["highway"]) for f in features] == [("way/1", "footway"), ("way/2", "steps")]
    assert features[0]["geometry"] == {"type": "LineString", "coordinates": [[0.0, 0.0], [0.001, 0.0]]}
