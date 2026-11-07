# ADR-001: MapKit drives the camera in both modes

*Status: Accepted. Confirmed in the iOS 27.1 Simulator and on an iPhone 12 · 2026-11-06*

## Context

Street Map is Apple's MapKit, and the Path Map is drawn by our own view
([ADR-002](002-flat-path-map.md)). Switching between them must not move the camera, so
they have to agree to within a pixel or two about where every point on campus appears.

MapKit doesn't document its camera: not its field of view, how it turns
`centerCoordinateDistance` into a camera position, or what map projection it draws.

## Decision

- MapKit owns gestures and the camera in both modes.
- In Path mode an opaque view sits on top. Touches pass through it to the map.
- Every display frame, that view reads `MKMapView.camera` and draws from it using the
  measured model below (`CampusGeo.CameraPose`).

Two exceptions:
- Path mode pans with its own one-finger gesture, because MapKit's fling momentum can't
  be switched off. It still moves MapKit's camera.
- Navigation drives the camera itself ([ADR-004](004-navigation.md)), and doesn't always
  tell MapKit.

## How MapKit's camera was measured

1. **Collect data.** The app moved MapKit through 24 camera states:
   - distance 200 / 500 / 1200 m
   - pitch 0 / 30 / 50 / 70°
   - heading 0 / 135°

   At each one it asked MapKit, with `convert(_:toCoordinateFrom:)`, which ground
   coordinate lies under each of 153 screen points: 3,672 correspondences in all.
2. **Fit a simple pinhole camera.** A Nelder–Mead fit of FOV, distance scale and
   principal-point offset left **4.4 pt RMS** error. The error grew with pitch, but not
   with distance or terrain: flat and realistic elevation gave identical numbers, because
   MapKit's conversions ignore terrain.
3. **Find the first cause.** Per-sample fits showed that even straight-down views had a
   **0.355% north–south stretch**. That is exactly the anisotropy you get from applying
   spherical Web Mercator to WGS84 coordinates at 43.47°N: (1 − e² sin²φ)/(1 − e²).
   Placing geometry in a local Web Mercator plane instead of true east/north meters
   (`CampusGeo.MapPlane`) took straight-down views to 0.000 pt.
4. **Find the second cause.** Tilted views still drifted. The model that fits every
   sample exactly:
   - The optical axis goes through the **middle of the view**, with no lens shift.
   - The center coordinate sits under the **middle of the safe area** (14 pt below
     the view's middle on an iPhone 17), and the camera orbits that point.
   - **Altitude = 1.001995 × distance × cos(pitch).** The eye lies on the ray through
     the safe-area center.
   - **Vertical FOV = 30.000°.**

| Model | Where | RMS error | Max error |
|---|---|---|---|
| Pinhole, true local meters | Simulator | 4.37 pt | 13.6 pt |
| Measured model (`MapKitCameraModel.measured`) | Simulator (anchor 0, 14) | **0.00002 pt** | 0.00006 pt |
| Measured model, unchanged | iPhone 12 (anchor 0, 6.5) | **0.00003 pt** | 0.00008 pt |

On the iPhone 12 a fresh fit returned the same constants: FOV 30.0000°, altitude
scale 1.001995. The fitted anchor (0, 6.5) is exactly what the safe-area insets
(47 pt top, 34 pt bottom) predict. The model carries over between devices without
recalibrating.

`MapKitFidelityTests` pins this model against recorded MapKit output, so a MapKit change
that breaks alignment fails a unit test.

## Other measurements

- **Closest zoom:**
  - About 88 m camera distance at any pitch (85 m on the iPhone 12's smaller screen).
  - Asking for less than about 30 m makes MapKit fall back to 44 m and pitch 0.
  - With a 30° FOV, 88 m still shows only about 22 m across a portrait screen.
- **Steepest pitch:**
  - 75° up to 300 m.
  - 70° at 600–1200 m.
  - 60° at 2.5 km.
  - Asking for more breaks the camera, so tilting to level isn't possible.
- **Animations:** `mapView.camera` reports intermediate values during
  `setCamera(_:animated: true)`, so the Path Map follows MapKit's own animations.
- **Controls:** MapKit's built-in compass, tracking and pitch buttons are subviews of
  the map, so the Path Map would cover them.
  - We use the standalone `MKCompassButton` and `MKUserTrackingButton` above it.
  - The 2D/3D toggle is our own, because `MKPitchControl` doesn't exist on iOS.

## Consequences

- All geometry lives in `MapPlane` (local Web Mercator), not true meters. True lengths
  for routing will be computed separately by the map compiler. Within campus the two
  differ by at most about 0.2%.
- Pinch, rotate, tilt and zoom limits are MapKit's own in both modes, at no cost.
- The Path Map depends on undocumented MapKit behavior, which `MapKitFidelityTests`
  guards after iOS updates.
