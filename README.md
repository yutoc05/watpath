# WatPath

An iPhone app for getting around the University of Waterloo campus while staying
indoors. It has two map modes that share one camera:
- **Street Map**: Apple Maps.
- **Path Map**: flat building footprints on black, with thin lines for corridors (white), bridges (blue) and tunnels (red).

Switching between them is like x-ray vision. The full plan is in [docs/PLAN.md](docs/PLAN.md).

[![A one-minute tour of WatPath: search, the Street and Path maps, directions from a pin inside MC, and walking the route to DC](docs/media/demo.gif)](docs/media/demo.mp4)

A one-minute tour, recorded in the Simulator. Click it for the [full-quality video](docs/media/demo.mp4).

**Status:** both maps and routing work:
- Street Map: door markers, place cards, and search (typo-tolerant, with Recents and Popular).
- Path Map: every building on one flat level, with thin lines for what's mapped.
- Directions: from a pin in the Path Map or a place outside, a choice of routes trading time against time outdoors, with stairs counted even though the map is flat.
- Navigation: drag anywhere to walk along a route, with the camera turning through its corners and the Street Map fading in outdoors.
- Both: choose-on-map, and one camera shared by the two modes.

[ADR-001](docs/adr/001-camera-architecture.md) explains the shared camera,
[ADR-002](docs/adr/002-flat-path-map.md) how the Path Map is drawn,
[ADR-003](docs/adr/003-routing.md) how routes are found, and
[ADR-004](docs/adr/004-navigation.md) how navigation moves.

## Requirements

- Xcode 27 (iOS 26 SDK or newer) and an iPhone running iOS 26+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)
- Python 3.12+ and [uv](https://docs.astral.sh/uv/) for the data tools and their tests

## Getting started

```sh
make project   # generate WatPath.xcodeproj from project.yml
make data      # compile data/ into build/CampusBundle
make sim       # build and run in the Simulator
make test      # Python + Swift unit tests
make uitest    # UI flow tests in the Simulator
make demo      # record the walkthrough and cut docs/media/demo.mp4
```


### Running on an iPhone with a free Apple ID

1. Run `make project` and open `WatPath.xcodeproj`.
2. In the WatPath target, go to **Signing & Capabilities** and pick your Personal Team.
3. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and put your team ID
   in it, so regenerating the project keeps it.
4. Run `make device`. On the first launch, trust the developer certificate on the phone:
   **Settings → General → VPN & Device Management**.

Free provisioning expires after 7 days. Run `make device` again to re-sign.

## Repository layout

| Path | Contents |
|---|---|
| `App/` | The iOS app (SwiftUI shell, MapKit Street Map, Core Animation Path Map) |
| `Packages/WatPathKit/` | Platform-independent modules: `CampusGeo` (map projection, camera model, geometry), `CampusModel` (bundle types), `CampusSearch` (offline search, recents), `Routing` (walking graph, route search, directions flow, navigation) |
| `AppUITests/` | UI flow tests |
| `data/` | Map source data: hand-curated `campus/` and generated `osm/` |
| `tools/` | OSM importer, map compiler, build and run scripts, and `demo/`, which records and cuts the demo video |
| `design/` | The app icon's source |
| `docs/` | Plan, decision records, generated coverage report, survey checklist, and the demo video in `media/` |

## Data and licenses

Building outlines come from [OpenStreetMap](https://www.openstreetmap.org/copyright),
© OpenStreetMap contributors, available under the ODbL. UW floor plans are never
committed (`data/private/` is gitignored).

Inspired by *Toronto PATH Navigation* by Area 43 Labs.
