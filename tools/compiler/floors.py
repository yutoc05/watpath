"""Floors per building: what each building has, for its place card and for the floor
numbers at each end of a bridge or tunnel. The Path Map itself has no floors.
"""

from __future__ import annotations

import math
import re

from issues import Issue

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


def ordinal(name: str) -> float:
    """Where a floor sits in storeys: floor 1 is 1, the basement 0, "2M" (the 2nd-floor
    mezzanine) 2.5, and the penthouse above every numbered floor."""
    if name.isdigit():
        return int(name)
    if name in SPECIAL_FLOORS:
        return SPECIAL_FLOORS[name][0]
    if match := MEZZANINE.match(name):
        return int(match.group(1)) + 0.5
    if name == PENTHOUSE:
        return math.inf
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
