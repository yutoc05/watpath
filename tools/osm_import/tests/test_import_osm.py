from import_osm import assemble_rings, build_entrances, build_features, element_polygons, signed_area


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
