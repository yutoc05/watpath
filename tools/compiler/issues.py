from dataclasses import dataclass


@dataclass(frozen=True)
class Issue:
    severity: str  # "error" fails the build, "warning" is reported only
    message: str
