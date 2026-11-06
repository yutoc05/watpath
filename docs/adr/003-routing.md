# ADR-003: Routes know about floors the map doesn't show

*Status: Accepted · 2026-11-06*

## Context

The Path Map is flat ([ADR-002](002-flat-path-map.md)), but campus isn't. The bridge from MC reaches QNC on floor 2, and the one from E3 leaves on floor 4. A route through E3 from one to the other involves stairs that no line shows.

Routes also have to trade time against time outside. Someone choosing between walking across the quad and going through three buildings wants to see both, with honest numbers, and offline.

## Decision

### One graph, built ahead of time

`tools/compiler/graph.py` builds one walking graph from three sources, and ships it as `graph.json`:

- **Indoors:** the Path Map's own lines, so a route can only go where the map shows a line. Lines join only at shared vertices, and the compiler rejects a line that stops within 1 m of another without sharing one.
- **Outdoors:** OSM footpaths. Ring Road and bigger roads are left out, because their sidewalks and crossings are mapped separately.
- **Doors:** the join. A straight stub reaches the nearest corridor, as long as it stays inside the building, and another reaches the nearest footpath, as long as it doesn't cross a building.

A door that only lets people out has a one-way stub. You can still walk up to it from outside: it just doesn't let you in.

### Floors live on the edges that change them

Search runs over (node, floor), not nodes alone. A corridor keeps the floor you're on. A bridge, tunnel or link says what floor it takes you from and to, and charges for the stairs to reach it. A two-storey bridge offers both ways across, and the search takes whichever needs fewer stairs. Where a corridor passes into the next building, a zero-length link carries the change of numbering (DC's floor 2 is E3's floor 3).

**An unknown floor is never guessed, and costs nothing.** You start on an unknown floor, and going outside forgets the floor. The estimate can only be low, never padded. Door levels from OSM are ignored until a door is surveyed, because OSM counts from 0 and no sign on campus does.

This is the same state expansion road routers use for turn costs. It stays small: about 3,400 nodes and 5 floor values, and most of those pairs are never reached.

### Several routes from one idea: how much is outside worth?

The planner runs the search with `cost = t_inside + λ·t_outside` for λ from 1 to 50, then keeps what's worth choosing between:

1. Drop anything taking more than 1.6× as long as the fastest (or two minutes longer, on short walks). PAC to HH has a 95% indoor route, at 15 minutes against 8.
2. Drop anything beaten on both time and meters outside (the Pareto front).
3. Keep the fastest and the most indoor. Add others only if they share less than 80% of their length with what's kept, or spare at least 30 m outside.

One λ-sweep finds only points on the convex hull of that front, so some trade-offs in between are missed. That's acceptable: the ones that matter are the ends.

When nothing is traded for anything, there's one route, labelled "Best route". The plan's "2–4 routes" is a limit, not a quota: offering a worse route to fill out a list isn't a choice.

### Pins don't change the graph

A pin joins the nearest edge through temporary attachments to that edge's two ends, so one graph serves any number of searches without being copied or locked. Two pins on one edge get a direct walk, since neither would otherwise reach a node.

## Measured

On an iPhone 12, in a Debug build, off the main thread:

| Step | Time |
|---|---|
| Load the graph | 42 ms |
| Prepare the router | 8 ms |
| Join a pin to the graph | 4 ms |
| Find a route list, mean of all 1,406 building pairs | 22 ms |
| Find a route list, slowest pair | 108 ms |

## Consequences

- **Times are estimates that lean low**, until the survey adds door levels.
- **Stubs are the one place a route draws a line the Path Map doesn't.** A route through a door has to reach the corridor somehow, and the straight line inside the building is a stand-in for a room or hallway we haven't mapped. They appear only on a route, never on the map itself.
- **Buildings with no lines** (CIF, DP, ERC, LHI, M3, OPT, PAC, PAS) can be reached but not crossed: routes end at their doors. Giving them lines later is a data change.
- **ESC–EIT tunnel:** it has no line, so routes can't use it until it's mapped.
- **Nothing is known about hours, locks or accessibility.** A route may use a door that's locked at night, or stairs someone can't climb.
