"""Floors per building and the height of each, solved from the connections.

UW's floor numbers don't line up between buildings: MC's floor 3 meets QNC's
floor 2, and C2's basement meets MC's floor 1. Every bridge or tunnel says "floor
a of A is at the same height as floor b of B", so the ground-floor height of each
building is the least-squares solution of those equations, with a weak pull
toward 0 so buildings without connections stay at ground level.
"""

from __future__ import annotations

import re

from issues import Issue

# How strongly an unconnected building is held at 0 m, relative to one connection.
GROUND_WEIGHT = 0.01
# Connections that disagree by more than this after solving are reported.
TOLERANCE_METERS = 0.5
# Floors that aren't numbered, by their short names (Plant Operations' floor plans):
# where each sits relative to floor 1, and what to call it in full.
SPECIAL_FLOORS = {
    "B": (0.0, "Basement"),
    "MB": (0.5, "Midlevel basement"),
    "LL": (0.0, "Lower level"),
    "C": (0.0, "Concourse"),
    "M": (0.5, "Mezzanine"),
}
MEZZANINE = re.compile(r"^(\d+)M$")
PENTHOUSE = "P"


def ordinal(name: str, top: int = 0) -> float:
    """Where a floor sits in storeys: floor 1 is 1, the basement 0, "2M" (the 2nd-floor
    mezzanine) 2.5. The penthouse sits above `top`, the highest numbered floor."""
    if name.isdigit():
        return int(name)
    if name in SPECIAL_FLOORS:
        return SPECIAL_FLOORS[name][0]
    if match := MEZZANINE.match(name):
        return int(match.group(1)) + 0.5
    if name == PENTHOUSE:
        return top + 1
    raise ValueError(f"unknown floor name {name!r}")


def title(name: str) -> str:
    """The floor's full name: "Floor 3", "Basement", "2nd floor mezzanine"."""
    if name.isdigit():
        return f"Floor {name}"
    if name in SPECIAL_FLOORS:
        return SPECIAL_FLOORS[name][1]
    if match := MEZZANINE.match(name):
        number = int(match.group(1))
        suffix = "th" if 10 <= number % 100 <= 20 else {1: "st", 2: "nd", 3: "rd"}.get(number % 10, "th")
        return f"{number}{suffix} floor mezzanine"
    return "Penthouse" if name == PENTHOUSE else name


def floor_names(above_ground: int, referenced: set[str], code: str, issues: list[Issue], official: list[str] | None = None) -> list[str]:
    """Floors bottom to top. The official list when there is one (every floor a
    connection reaches must be on it); otherwise a guess: the basement if a
    connection uses it, then 1…top, covering the level count and every floor reached."""
    for name in sorted(referenced):
        try:
            ordinal(name)
        except ValueError as error:
            issues.append(Issue("error", f"{code}: {error}"))
    if official is not None:
        for name in official:
            try:
                ordinal(name)
            except ValueError as error:
                issues.append(Issue("error", f"{code}: {error}"))
        for name in sorted(referenced - set(official)):
            issues.append(Issue("error", f"{code}: a connection meets floor {name!r}, which isn't in its floors"))
        return list(official)
    numbered = [int(n) for n in referenced if n.isdigit()]
    below = sorted((n for n in referenced if not n.isdigit() and _safe_ordinal(n) < 1), key=_safe_ordinal)
    return below + [str(n) for n in range(1, max([above_ground, *numbered]) + 1)]


def _safe_ordinal(name: str) -> float:
    try:
        return ordinal(name)
    except ValueError:
        return 1.0


def solve_ground_elevations(
    buildings: list[dict], connections: list[dict], issues: list[Issue]
) -> dict[str, float]:
    """Height of each building's floor 1, in meters, from connection floor pairs."""
    codes = [b["code"] for b in buildings]
    index = {code: i for i, code in enumerate(codes)}
    height = {b["code"]: b["levelHeight"] for b in buildings}
    # Rows of (coefficients by building index, constant, weight, description).
    rows: list[tuple[dict[int, float], float, float, str]] = [({i: 1.0}, 0.0, GROUND_WEIGHT, "") for i in range(len(codes))]
    for connection in connections:
        ends = [e for e in connection["ends"] if e["floors"]]
        for deck in range(max((len(e["floors"]) for e in ends), default=0)):
            first, *others = [(e["building"], e["floors"][min(deck, len(e["floors"]) - 1)]) for e in ends]
            for other in others:
                # ground[A] + (ord(a) - 1) h_A = ground[B] + (ord(b) - 1) h_B
                (a, fa), (b, fb) = first, other
                constant = (ordinal(fb) - 1) * height[b] - (ordinal(fa) - 1) * height[a]
                rows.append(({index[a]: 1.0, index[b]: -1.0}, constant, 1.0, f"{connection['id']}: {a} {fa} = {b} {fb}"))

    n = len(codes)
    normal = [[0.0] * n for _ in range(n)]
    rhs = [0.0] * n
    for coefficients, constant, weight, _ in rows:
        for i, ci in coefficients.items():
            rhs[i] += weight * ci * constant
            for j, cj in coefficients.items():
                normal[i][j] += weight * ci * cj
    ground = solve(normal, rhs)

    for coefficients, constant, weight, description in rows:
        if weight < 1:
            continue
        residual = sum(c * ground[i] for i, c in coefficients.items()) - constant
        if abs(residual) > TOLERANCE_METERS:
            issues.append(Issue("warning", f"{description} is off by {residual:.1f} m after solving (floors disagree around a loop)"))
    return {code: round(ground[index[code]], 2) + 0.0 for code in codes}


def solve(matrix: list[list[float]], rhs: list[float]) -> list[float]:
    """Gaussian elimination with partial pivoting (the system is small and well posed)."""
    n = len(rhs)
    a = [row[:] + [value] for row, value in zip(matrix, rhs)]
    for column in range(n):
        pivot = max(range(column, n), key=lambda r: abs(a[r][column]))
        a[column], a[pivot] = a[pivot], a[column]
        for r in range(column + 1, n):
            factor = a[r][column] / a[column][column]
            if factor:
                for c in range(column, n + 1):
                    a[r][c] -= factor * a[column][c]
    x = [0.0] * n
    for r in reversed(range(n)):
        x[r] = (a[r][n] - sum(a[r][c] * x[c] for c in range(r + 1, n))) / a[r][r]
    return x
