# WatPath: Project Plan

*Status: Street Map, Path Map, routing and scrub navigation work, and the app has its icon, colors and demo video. The rest of polish is next, and the door survey is still to do · Last updated 2026-11-13*

WatPath is an iPhone app for getting around the University of Waterloo main campus while staying indoors. It's closely modeled on *Toronto PATH Navigation* (Area 43 Labs). It has two map modes that share one camera, so switching between them feels like x-ray vision:

- **Street Map**: Apple Maps plus clickable building doors with photos.
- **Path Map**: flat building footprints on black, with thin lines for corridors (white), bridges (blue) and tunnels (red).

On top of the maps, the app finds several routes that trade speed against time outside. Navigation is a drag-to-scrub walkthrough of the chosen route.

---

## 1. Decisions

| Topic | Decision | Why |
|---|---|---|
| Device | iPhone 12 (A14, 4 GB RAM, 60 Hz) | It's the performance floor, so we budget for it. |
| Minimum iOS | **26.0** | Excludes almost nothing, and gives the Liquid Glass look of current Apple Maps. |
| Distribution | Free Apple ID ("Personal Team") | No paid account. The app expires 7 days after install, so it's re-signed weekly. There's no TestFlight. For interviews, use the phone itself plus a recorded demo video. |
| Language/UI | Swift 6 (strict concurrency), SwiftUI shell | Modern, and expected in interviews. |
| Street Map | MapKit with UIKit `MKMapView`, wrapped for SwiftUI | Needs frame-by-frame camera access and fine annotation control. |
| Path Map | One opaque 2D view over the map, drawn with Core Animation ([ADR-002](adr/002-flat-path-map.md)) | The map is flat, and MapKit overlays can't keep up with fast moves. |
| Camera | MapKit owns gestures and the camera in both modes ([ADR-001](adr/001-camera-architecture.md)) | Its camera is modeled exactly (≤ 0.00003 pt RMS), so the x-ray switch costs nothing. |
| Data strategy | **Whole-campus skeleton first, then fill in detail** | Gives a working end-to-end app early. |
| Routing | Floor-aware search over one compiled graph ([ADR-003](adr/003-routing.md)) | The map is flat, the buildings aren't, and it all has to work offline. |
| Backend | None. All data ships inside the app. | Nothing to host, and it works offline. |
| Out of scope | Live GPS follow-me navigation, Android, accounts, residences, university colleges, satellite campuses | Agreed scope. |

## 2. Campus scope

**In scope: 38 buildings.** The Field House counts as part of CIF, and the CIM block as part of DC.

| Group | Buildings |
|---|---|
| Core (38) | EXP (Health Expansion), AL (Arts Lecture Hall), B1, B2 (Biology 1/2), BMH (B.C. Matthews Hall), C2 (Chemistry 2), CIF (Columbia Icefield, with the Feridun Hamdullahpur Field House), CPH (Carl A. Pollock Hall), DC (William G. Davis Computer Research Centre), DWE (Douglas Wright Engineering), E2, E3, E5, E6 (Engineering 2/3/5/6), PSE (Pearl Sullivan Engineering, formerly E7), EIT (Environmental & Information Technology), ERC (Energy Research Centre), ESC (Earth Sciences & Chemistry), EV1, EV2, EV3 (Environment 1/2/3), HH (Hagey Hall), LHI (Lyle S. Hallman Institute), DP (Dana Porter Library), M3 (Mathematics 3), MC (Mathematics & Computer), ML (Modern Languages), NH (Needles Hall), OPT (Optometry & Vision Science), PAC (Physical Activities Complex), PAS (Psychology, Anthropology & Sociology), PHY (Physics), QNC (Quantum Nano Centre), RCH (J.R. Coutts Engineering Lecture Hall), SCH (South Campus Hall), SLC (Student Life Centre), STC (Science Teaching Complex), TC (Tatham Centre) |

**Out of scope:**
- **Residences:** V1, REV, MKV, UWP, CMH, MHR, CLV, Tutor's Houses.
- **University colleges:** St. Jerome's, Renison, Conrad Grebel, United College.
- **Satellite campuses.**
- **Service and operations buildings:** GSC, CSB, COM, BAU.
- **North campus / R+T Park:** TJB, RAC1/2, Accelerator Centre.
- **Small ancillary buildings:** Brubacher House, Bright Starts.
- **Also excluded:** East Campus (EC1–EC5, ECH), Federation Hall (FED), Graduate House (GH), Health Services (HS), University Club (UC).

**Known campus changes:**
- The DC–MC and MC–M3 bridges were demolished in December 2024 for M4. M4 opens in 2027 and will restore those links. Until then, M4 is excluded and the links are absent.
- E7 was renamed PSE in November 2025, so search treats "E7" as an alias.

The inventory lives in `data/campus/inventory.json`, so adding a building later is a data change, not a code change.

## 3. Features

### 3.1 Street Map
- [x] Full-screen Apple map with realistic 3D elevation. Pan, pinch-zoom, rotate and two-finger tilt, all native.
- [x] Compass (only appears when rotated), 2D/3D toggle, locate-me (blue dot, follow, heading).
- [x] A door marker for every mapped entrance of an in-scope building, styled like a native Apple POI, shown only when zoomed in so the map stays uncluttered.
- [x] Tapping a door opens a place card with its name, building, level, accessibility notes and photos (or a placeholder).
- [x] Tapping a building opens its place card: name, code, aliases, every floor, entrances.
- [x] Dragging a card down shrinks it to its smallest size but never closes it. That's what its X is for.

### 3.2 Path Map
- [x] **Simple, and only what we know** ([ADR-002](adr/002-flat-path-map.md)): every building is a flat footprint on black, all on one visual level, with no walls and no floors.
- [x] Thin lines, 1.5 pt at every zoom and tilt: corridors white, bridges blue, tunnels red. They live in `data/campus/lines.geojson`.
  - **A line exists only where a route is mapped.** Nothing is guessed, so a connection with no mapped route has no line. `docs/coverage.md` lists them.
  - Corridors stay inside buildings: the compiler rejects one that doesn't. Every corridor leads to a bridge, a tunnel, a door or an adjoining building. CIF, DP, ERC, LHI, M3, OPT and PAS have no lines, and PAC only has the SLC corridor reaching its edge.
  - A bridge or tunnel is blue or red only outside buildings, and runs on in white inside.
  - Where OSM drew a bridge as a thin arm of a building's outline (E3's E5 bridge, SLC's MC bridge and others), the arm is cut out, so a bridge is only ever a line.
  - Where two buildings touch (B1–ESC, CPH–DWE), the bridge is a short blue section of the corridor at the join.
- [x] The floor(s) a bridge or tunnel meets are labeled at its two ends. These numbers are the only floors on the map.
- [x] The same gestures and controls as Street Map. One exception: one-finger pans are ours, 1:1 with the finger and with no glide on release, since MapKit's fling momentum can't be switched off.
- [x] Door markers never take touches: a drag that starts on one moves the map, and the map's tap handler hit-tests them. They give way to labels, floor numbers and each other.
- [x] A building label (code, plus the full name when zoomed in) that stays upright and readable and avoids overlapping other labels.
- [ ] Line fixes as they're checked on site.

### 3.3 Mode switch
- [x] One tap switches modes with a cross-fade of ≤ 250 ms. **The camera does not move.**

### 3.4 Search (both modes)
- [x] A top search bar. Results come from our own index (buildings with aliases like "Dana Porter" → DP, "E7" → PSE and "Davis Centre" → DC, and doors), merged with Apple's `MKLocalSearchCompleter` results for anything else.
- [x] Ranking tolerates typos (prefix, token and edit-distance scoring).
- [x] **Popular Locations** (curated) and **Recent Locations** (saved on the phone, newest first, de-duplicated).
- [x] The keyboard drops the moment you leave the search, by any route, rather than after the panel slides away.
- [x] **Choose location on map**: a pin fixed at screen center, a live lat/long readout, and a confirm button.
- [x] **Choose location inside the path**: the same, in Path Map. On release, the pin snaps to the nearest point inside a building.

### 3.5 Directions
- [x] Every place card has a **Directions** button, which leads to a prompt: **"I'm in the PATH"** or **"I'm Outside"**.
- [x] *I'm in the PATH*: Path Map opens in pin-picking mode. The pin starts at your current location if you're inside an in-scope building, otherwise at the screen center. Dropping it in the black animates it to the nearest walkable point.
- [x] *I'm Outside*: an origin search with Current Location, search, recents, popular and choose-on-map.
- [x] A route list of up to 4 genuinely different routes. Each shows: total minutes, total distance, % inside (as a small bar), inside length, outside length, the buildings it passes through, floors to change, and a label (Fastest / Balanced / Less outside / Most indoor, or Best route when there's only one).
- [x] Selecting a route previews it on both maps, with the camera framing the whole route. Door markers step aside while a route is on show.
- [x] The routes scroll inside the card under a fixed header, so the map stays in view.
- [x] The search bar is gone throughout directions, so the Street/Path toggle moves up into its place, and returns when directions end.
- [x] A **Start** button on each route.

### 3.6 Navigation (scrub mode)
- [x] Start flies to the route start on the Path Map, with the route drawn as a dotted line in the accent color, a Canada goose standing on it, and a green flag at its end.
- [x] A vertical drag anywhere scrubs along the route: drag **down = forward**, drag **up = back**, with flick momentum. The camera follows the route through turns. The user never has to move the camera by hand, and can't: the map's own gestures are off.
- [x] A horizontal drag turns the camera around the goose, and a pinch zooms, with the goose staying put on screen. A drag does one or the other, settled by which way it first moves. Lifting the finger swings the camera back to straight ahead, carrying on first if the turn was flicked.
- [x] Top progress bar: a goose moves toward a green flag.
- [x] Bottom ETA card: arrival time, minutes and distance remaining, an End button. At the end of the route it says you've arrived, until you scrub back.
- [x] Outdoor stretches of 12 m or more fade to the Street Map, and back.
- [x] Holds 60 fps on iPhone 12: 2.5 ms of hitches per second, indoors and out ([ADR-004](adr/004-navigation.md)).

### 3.7 Look and demo
- [x] The app icon is the navigation goose on its path, on marigold. Its source is `design/app-icon.svg`. It was picked on 2026-11-13 from eight directions, with the wordmark in Quicksand.
- [x] A honey accent (#B97300) on buttons, the picked route and the progress bar, with sand for routes not picked. The Path Map keeps its white, blue and red lines, and your location stays blue.
- [x] A one-minute demo video in the README. A UI test (`AppUITests/DemoTour.swift`) plays the tour while the Simulator records, and `tools/demo` cuts it, trims the waits and adds the intro and captions (`make demo`). Debug builds draw a circle under each finger when launched with `-showTouches`, so the recording shows the gestures.

## 4. Architecture

```
┌──────────────────────────── SwiftUI app shell ────────────────────────────┐
│ Search · Mode switch · Map controls · Sheets (search/place/routes)        │
│ AppModel (@Observable) · DirectionsFlow (state machine)                   │
└───────────────┬────────────────────────────────────────┬──────────────────┘
                │                                        │
     CampusMapController (UIKit)                     Search · Routing
  ┌─────────────┴───────────────────┐                    │
  │ PathMapView (opaque in Path     │◀── camera model ───┤ (camera each frame)
  │   mode, no touches)             │                    │
  │ MKMapView (owns gestures and    │                    │
  │   the camera in both modes)     │                    │
  └─────────────────────────────────┘                    │
              ▲                                          ▲
              └──── CampusModel (loads CampusBundle) ────┘
                              ▲
           tools/compiler (Python) builds the bundle from data/ (GeoJSON)
```

**Coordinates:**
- **Source data:** WGS84 lat/long in GeoJSON.
- **`MapPlane`:** MapKit's own projection, a local Web Mercator plane centered near MC and scaled to meters there. True east/north meters would drift about 2 m from MapKit's drawing at the edge of campus.
- **Route lengths** are true meters, computed by the compiler. On campus they differ from plane distances by at most about 0.2%.
- **Floors** are named **per building**, as signed: MC's floor 3 meets QNC's floor 2, and C2's basement meets MC's floor 1. Each connection end names its building and floor(s). Floors have no height: the map is flat.

**Modules** (one local package, `Packages/WatPathKit`):

| Module | Contents |
|---|---|
| `CampusGeo` | `MapPlane`, MapKit camera model, `GroundProjection`, polygon geometry. Runs on Linux, so CI is cheap. |
| `CampusModel` | Data types and bundle decoding. Runs on Linux. |
| `CampusSearch` | Local index and typo-tolerant ranking. |
| `Routing` | Walking graph, floor-aware search, snapping, route lists, `DirectionsFlow`, and navigation's `NavigationRig`. Runs on Linux, heavily tested. |
| App target | SwiftUI features, `CampusMapController`, `PathMapView`. |

**`DirectionsFlow`** is an explicit, unit-tested state machine. It's generic over the place type, so it runs without a screen:

```
idle → originPrompt → pickingOriginInPath ─────────┐
                    → searchingOrigin ─────────────┤→ findingRoutes → routes | noRoutes
                        → pickingOriginOnMap ──────┘
routes → navigating ⇄ arrived
```

**Performance budget (iPhone 12):**

| Metric | Target |
|---|---|
| Frame rate | 60 fps during pan and zoom in Path mode, and during scrubbing |
| Launch | ≤ 1.5 s from cold launch to an interactive map |
| Memory | ≤ 400 MB |
| App size | ≤ ~80 MB. Photos dominate: resize to 1600 px HEIC plus thumbnails. |

Measure on the phone, with Instruments' Animation Hitches as well as app timers: the render server's cost doesn't show up in the app ([ADR-002](adr/002-flat-path-map.md)). Keep recordings few, and let each one finish saving, which can take over a minute: they leave data on the phone, and filled its storage twice.

## 5. Data

### 5.1 Sources
- **OpenStreetMap:** building outlines, entrances, bridges and tunnels. License is ODbL. The app shows "© OpenStreetMap contributors", and `data/` is licensed ODbL.
- **Plant Operations' floor-plan index** (uwaterloo.ca/plant-operations/floor-plans): the public list of each building's floors, recorded as `floors` in the inventory. EXP isn't listed, and has BMH's floors.
- **UW floor plans:** anything from these stays in `data/private/` (gitignored) and never ships. Keep the GitHub repo **private** until Plant Operations has OK'd publishing.
- **On-site survey:** verify every door and connection, and take every photo yourself.

### 5.2 Files

Hand-authored and generated files are kept apart, so re-importing from OSM never overwrites hand edits:

```
data/
  campus/campus.json        # map origin
  campus/inventory.json     # in-scope buildings: code, names, aliases, priority, OSM match, floors, label
  campus/popular.json       # curated Popular Locations
  campus/doors.json         # hand edits to doors, plus doors OSM lacks
  campus/connections.json   # hand edits to bridges/tunnels/links, plus ones OSM lacks
  campus/lines.geojson      # the Path Map's lines: corridors, bridges, tunnels
  osm/buildings.geojson     # GENERATED by tools/osm_import: building outlines and level counts
  osm/entrances.geojson     # GENERATED: public entrances on in-scope outlines
  osm/connections.geojson   # GENERATED: bridges, tunnels and links reaching two or more in-scope buildings
  osm/footpaths.geojson     # GENERATED: outdoor ways open to pedestrians
  photos/<door-id>/         # door photos
  private/                  # gitignored
```

### 5.3 Map compiler (`tools/compiler`, Python + pytest)

`make data` compiles `data/` into `build/CampusBundle`. It validates the inventory, applies hand edits to doors and connections, attaches `lines.geojson` to corridors and connections (`lines.py`), rejects any corridor that leaves the buildings, assigns floors (`floors.py`), cuts bridge arms out of building outlines (`arms.py`: parts narrower than 6 m, found by morphological opening, that a bridge runs along), finds the dividers between buildings that touch (`dividers.py`), and builds the walking graph (`graph.py`), which goes in its own file, `graph.json`, so it doesn't slow launch.

It also writes two generated docs: `docs/coverage.md`, each building's progress and what routing can't reach yet, and `docs/survey.md`, the checklist of every unverified door and connection, with map links.

The output is deterministic. The Xcode build only *checks* that the bundle's source hash matches `data/`, and fails with a "run `make data`" message if not. Xcode never runs Python.

### 5.4 Detail tiers

| Tier | Contents | Goal |
|---|---|---|
| **0: Shells** | Outline, floors, label | All 38, done |
| **1: Connectivity** | Every public door verified on foot, every bridge and tunnel | All 38, on site |
| **Later** | Door photos, named places, room numbers as destinations | Ongoing |

**Survey routine, per building:** check it on the phone, walk it, record doors and connections in `data/campus/`, take one wide photo from outside and one from inside per door, then `make data`.

## 6. Routing

The decisions, and why, are in [ADR-003](adr/003-routing.md).

- **Graph:** built by the compiler (`graph.py`) into `graph.json`, about 3,400 nodes and 4,300 edges.
  - **Indoors:** `lines.geojson`. Lines share exact vertices, so they split cleanly at every junction, and the compiler rejects a line that stops just short of another.
  - **Outdoors:** footpaths imported from OSM, keeping only the largest connected network.
  - **Doors:** each joins the nearest corridor and the nearest footpath in a straight line, if that line stays inside the building and out of other buildings. Exit-only doors let people out but not in.
  - **Between buildings:** where a corridor crosses into the next building, each side gets its own node, joined by a zero-length link carrying the floors.
  - **Arrival:** a building with lines has one arrival point, the nearest point on them to its middle. A building without lines is reached at any of its doors.
  - Edges carry true length (m), kind (`corridor`, `door`, `bridge`, `tunnel`, `link`, `outdoor`), the building, and `floors` where they change floor. Closed connections are left out.
- **Floors:** search runs over (node, floor). An edge with `floors` charges for the stairs to reach it and sets the floor on its far side, so moving between two connections in one building costs the storeys between them. Unknown floors are free, and only surveyed doors have a floor.
- **Time model (`TimeModel`):** walking at 1.3 m/s, 15 s per storey, 5 s per door. All constants live in that one file.
- **Multiple routes:**
  1. Run Dijkstra with cost = `t_inside + λ·t_outside`, for λ ∈ {1, 1.25, 1.5, 2, 3, 5, 10, 50}.
  2. Drop routes more than 1.6× the fastest (or 2 minutes longer, on short walks).
  3. Remove routes beaten on both total time and outside length (keep the Pareto front).
  4. Keep the fastest and the most indoor, and any other that shares under 80% of its length with those or spares at least 30 m outside.
  5. Label them. One route is "Best route".
- **Endpoints:** a pin joins the nearest edge through temporary attachments to that edge's ends, so the graph itself never changes. A pin in a building with no lines joins that building's doors. Farther than 300 m from anything walkable, a place is off the map.
- **Metrics:** totals of distance, time, inside and outside length are summed along the walk, including the stretch from a pin to the graph. % inside = inside / total distance.
- **Tests:** small hand-built graphs with known answers, and checks on the real campus that re-run on every data change: every building reaches every other, every door is reachable, no listed route is beaten on both measures, the first route is truly the fastest, and the routes along the main spine stay indoors.

## 7. Navigation

The decisions, and why, are in [ADR-004](adr/004-navigation.md). All of this but the drawing is plain values in `Routing` (`NavigationRig`), tested without a screen. Every constant lives in `NavigationTuning`.

- **The route:** `RouteTrack` turns a distance s along the route into a spot on the map. The dotted line follows the route exactly. The camera follows a rounded copy (a centripetal Catmull-Rom spline through points 6 m apart), read by step and not by length, so the two can't drift apart.
- **The dots** are placed every 3.5 m on the ground and projected each frame, so they stay put as the camera moves. A dash pattern would slide along the line.
- **Drag input:** Δs = Δy·k, where k is the ground the finger drags past the walker times a gain of 1.5, with drag down moving forward. Flicks coast and slow down as a `UIScrollView` does, up to 150 m/s, and a finger coming down catches them. s is clamped to [0, L].
- **Camera aim:** the walker stays 60% of the way down the screen. The camera faces the direction of `P̃(s+8 m) − P̃(s−4 m)`, eased with a critically damped spring (6 rad/s), so corners never snap. A user's turn sits on top of that, on a slower spring (4 rad/s) that takes over from the finger's speed when it lifts.
- **Camera position:** pitch 70° and distance 130 m. MapKit's long lens flattens perspective, so that looks less steep than it sounds. A pinch moves the camera between 90 m, near MapKit's closest ([ADR-001](adr/001-camera-architecture.md)), and 600 m, past which MapKit flattens steep pitches by itself.
- **Progress and ETA:** progress = s/L. Each stretch of the route knows how long it takes, including its doors and stairs, so time remaining comes from the time model at s. Arrival = now + time remaining.
- **Outdoor stretches:** the Path Map fades to reveal Apple Maps underneath. That's free because the camera is shared. MapKit sleeps while nobody can see it, and wakes 60 m before a stretch.
- **Tests:** the track, motion, spring, flight and rig each have unit tests, and the flow has UI tests. Real walks check that the camera never falls behind the walker.

## 8. Repository and practices

```
watpath/
  project.yml            # XcodeGen: the project is reviewable YAML, no hand-edited .pbxproj
  Config/                # xcconfig; Local.xcconfig (gitignored) holds your signing team
  App/                   # app target
  AppUITests/            # UI flow tests
  Packages/WatPathKit/   # CampusGeo, CampusModel, CampusSearch, Routing
  data/                  # source data (ODbL); data/private/ gitignored
  tools/compiler/        # Python map compiler + tests
  tools/osm_import/      # OSM importer + tests
  tools/demo/            # records the walkthrough and cuts the demo video
  design/                # app icon source
  docs/                  # this plan, decision records, generated coverage and survey, demo video
  Makefile               # make project · data · test · uitest · sim · device · demo
```

- **Tests:** Swift Testing for packages, XCUITest for the main flows, pytest for the tools.
- **CI (GitHub Actions):** the Linux-compatible packages, the tools and the data. macOS runners have limited free minutes on private repos.
- **Logging:** `os.Logger`, with categories per subsystem.
- **Accessibility:** VoiceOver labels on every control, Dynamic Type, Reduce Motion (cross-fades replace camera flights).
- **Decision records:** one short ADR per major decision.

## 9. Phases

| Phase | Deliverables | Exit criteria |
|---|---|---|
| **Street Map** ✅ | Map and controls, door markers, place cards, search, Popular, Recents, choose-on-map | Every building searchable, every known door tappable |
| **Path Map** ✅ | Compiler, flat Path Map, lines, floor numbers, labels, cross-fade | Switch modes anywhere on campus without the camera moving |
| **Routing** ✅ | Footpaths, graph, `Routing` package and tests, DirectionsFlow, both origin flows, route list | Any door or building to any other gives plausible, distinct routes with correct metrics |
| **Survey** | Tier 1 for all 38 (`docs/survey.md`), then line fixes. Runs alongside the rest, on site | Every door and connection verified |
| **Navigation** ✅ | Scrub gesture and momentum, camera rig, dotted route, progress bar, ETA card, arrival | 60 fps scrub along a route through 3 or more buildings: **app complete end-to-end** |
| **Polish** | ✅ App icon, colors and demo video. Still to do: animations, haptics, empty/error/permission states, onboarding, accessibility audit, performance pass | No known crashes; meets the performance budget; demo video recorded |

## 10. Risks

| Risk | Likelihood | Mitigation |
|---|---|---|
| A MapKit update changes its camera | Medium | `MapKitFidelityTests` pins the model against recorded MapKit output |
| Indoor location is inaccurate (Wi-Fi, ~10–30 m, no floor) | Certain | Show an accuracy halo, and never guess the floor; navigation is scrub-based anyway |
| Campus changes (M4 in 2027, construction closures) | Certain | Data versioned in git; a `closed` flag on connections; recompile |
| Publishing | Medium | The repo stays private; ask Plant Operations before making it public |
| 7-day free signing expiry | Certain | Weekly re-sign; demo video as backup for interviews |
| Looking like a copy of the original | Low | Own name, branding and icon; no UW logos; credit the inspiration in the README |
