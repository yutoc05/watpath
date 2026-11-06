# ADR-002: The Path Map is flat, and draws itself over the map

*Status: Accepted · 2026-11-06*

## Context

The Path Map was first built as a 3D model. Without precise floor plans that looked
messy and was inaccurate, so it was redesigned around one idea: **simple, and only
what we know.**

- Corridors, bridges and tunnels are thin lines: white, blue and red.
- There are no floors on the map. Every building is a flat footprint on one level.
  Floors stay on place cards, and as numbers at each end of a bridge or tunnel.
- There are no walls.
- A line exists only where a route is mapped. Nothing is guessed.

With no height left, a 3D engine has nothing to do.

## Decision

- **`PathMapView` is one opaque view over the map.** It never takes touches, so MapKit
  owns gestures and the camera ([ADR-001](001-camera-architecture.md)). Every frame it projects the ground from MapKit's
  camera and draws footprints and lines with `CAShapeLayer`s, then places labels,
  floor numbers, doors, the pin and the blue dot, all in one Core Animation transaction.
- **Modes cross-fade** by fading that view, so the camera can't move.
- **The ground is one plane**, so `GroundProjection` is the only projection the shapes
  need. It clips shapes just in front of the camera: a tilted camera has part of campus
  behind it, and dropping those points would wreck a filled building.
- **Overlapping outlines fill as one shape** (a non-zero fill, with rings wound
  consistently), so EV3 over EV2 has no seam. Hairlines between buildings that touch
  are compiled as `dividers`, and pairs that overlap get none.

## Why not MapKit overlays

The first version drew the black backdrop and footprints as MapKit overlays, and the
lines as polylines. Two things ruled that out, both of which only showed up in use.

**The backdrop can't keep up.** MapKit renders overlays in tiles. On a fast pan or zoom,
tiles that aren't ready yet show the street map through in patches. The black has to
be a view above the map, and then the map's overlays can't be seen either, so
everything in the Path Map has to be drawn here.

**Polylines dim on a tilted map.** MapKit fades a polyline wherever one of its 3D
buildings stands over it, like a route passing behind a building, and almost every
corridor is inside a building. Tried at the same tilt in the iOS 27.1 Simulator:

| Attempt | Result |
|---|---|
| `showsBuildings = false` | Ignored: buildings still present |
| `.flat` elevation, alone and with the above | Still dim |
| `.mutedStandard` via legacy `mapType` | Still dim |
| Hybrid or imagery with `.flat` elevation | Bright only because the camera won't tilt |
| Imagery with `.realistic` elevation | Tilts and stays bright, but the terrain pulls labels about 45 px off the lines |
| `MKGradientPolylineRenderer`, other blend modes | Still dim |
| `shouldRasterize = true` | Bright, but thick and soft, with width varying by direction and zoom |
| Zero-area `MKPolygon`, stroked | Same raster look; two-point lines vanish |

## Performance

Measured on an iPhone 12 in a Debug build, with a scripted fast pan, zoom and tilt
around the whole campus:

- **Main thread:** 1.35 ms per frame on average, 3.9 ms at worst, and 0 of 1,440 frames late.
- **Render server (Instruments, Animation Hitches):** a shadow on every label and a
  clip on every badge cost up to 148 offscreen passes a frame. Drawing the shadow into
  the text and rounding the badge's layer without clipping brought that to about 30.
  Hitches over a 22 s run halved from 28 to 14, and most of those are at launch and
  shutdown: 2 single-frame hitches across the 16 s of steady motion.

An app-side timer can't see the render server, so measure both.

## Consequences

- Much less to run than a 3D scene, and nothing in the Path Map can trail anything
  else, since it all moves in one transaction.
- MapKit keeps rendering under the opaque view while it's in Path mode.
- MapKit's logo and legal link are covered in Path mode.
- Thin arms OSM draws as part of a building (the E5 bridge is in E3's outline) are cut
  out by the compiler, so a bridge is only ever a line.
- `lines.geojson` is the single place to fix or add a line, and the compiler rejects a
  corridor that leaves the buildings. Phase 3's routing graph can be built from the
  same network, whose lines share exact endpoints.
