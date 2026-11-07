# ADR-004: Navigation moves the camera without MapKit

*Status: Accepted · 2026-11-07*

## Context

Navigation is a drag-to-scrub walk along a route: a finger moves the walker, and the camera follows through every corner, 60 times a second, on an iPhone 12. Live GPS follow-me is out of scope, so nothing but the finger moves it.

Until now MapKit owned the camera ([ADR-001](001-camera-architecture.md)). Here a route decides where the camera goes, a screen covering the map for most of the walk.

## Decision

### Everything that moves is a plain value

`NavigationRig` in the `Routing` package takes drags and flicks and gives back a `Pose` each frame: where the walker is, where the camera looks, and which way it faces. It knows nothing about MapKit or the screen, so all of it is tested without a device. Its parts are exact rather than stepped, so a dropped frame changes nothing:

- **`ScrubMotion`:** a flick decays as a `UIScrollView`'s does, using the integral of the decay rather than adding it up frame by frame. It goes the same distance at any frame rate.
- **`HeadingSpring`:** the closed-form solution of a critically damped spring, stable at any time step, always turning the short way around. It eases the camera through corners, and a second one brings a user's turn back: the finger's speed at the moment it lifts is the spring's starting speed, so a flick coasts and slows before the camera swings back.

### The camera follows a rounded route, by step

A camera that followed the route exactly would jerk at each corner. So the camera follows a centripetal Catmull-Rom spline through points 6 m apart, which rounds corners within a few meters, leaves straights straight, and doesn't overshoot.

The spline is shorter than the route, since it cuts corners. Read by length, that difference added up corner by corner, and the walker slid around the screen by 100 pixels partway along a route. So it's read by step instead: point n of the spline belongs to a fixed distance along the route, and the two can't drift apart.

### The overlay sits above both maps

The dotted line, goose and progress bar are drawn in their own view, over the Path Map and Street Map alike. An `MKPolyline` would dim under MapKit's 3D buildings at this tilt ([ADR-002](002-flat-path-map.md)), and would vanish with the Street Map as it fades.

Dots are projected from fixed places on the ground, 3.5 m apart. A dash pattern is measured along the line on screen, so it would slide along the route as the camera moves.

### MapKit sleeps while nobody can see it

In the first version, the camera went to MapKit every frame, as it does everywhere else. On the iPhone 12 the app's own work was small, at 0.6–1.2 ms a frame and 2.2 ms at worst, but frames still dropped. An all-indoor route settled why: it never shows the Street Map, yet Instruments blamed GPU work. MapKit was drawing 3D buildings, every frame, behind an opaque view.

So during navigation the rig's camera is the camera. While the Path Map fully covers the screen, MapKit is hidden and isn't told about it, and the overlays draw from the rig. The route says when an outdoor stretch is coming, so MapKit wakes 60 m early, while it's still covered. Because a hidden view takes no touches, the scrub gestures live on the container view.

When navigation ends, MapKit hears where the camera got to before it's shown again.

Measured on the iPhone 12 in a Debug build, in Instruments' Animation Hitches, over 20 s of steady scrubbing at 12 m/s:

| Route | MapKit always on (2 runs) | MapKit sleeping (1 run) |
|---|---|---|
| All indoors | 12–13 hitches, the worst 100–383 ms | 3 hitches, all a single frame: 2.5 ms/s |
| Mostly outdoors | 11–19 hitches, the worst 117–150 ms | 3 hitches, all a single frame: 2.5 ms/s |

Apple's guideline for smooth is under 5 ms of hitches per second. The worst moment in either new run was 50 ms, as navigation started and before any scrubbing.

## Consequences

- **The new numbers are one run each.** Runs of the same build varied a lot before this change, so a second pair would have been worth having, but each recording leaves data behind on the phone, and they filled its storage twice.
- **A hard flick could outrun MapKit's 60 m head start**, and show the Street Map a moment before its tiles load. Fades hide most of that.
- **The camera is ours during navigation**, so MapKit's limits are ours to keep. A pinch stops at 90 m and 600 m, which keeps a 70° pitch inside them.
- **VoiceOver can't scrub yet**, and Reduce Motion doesn't shorten the flight to the start. Both belong to the polish pass.
