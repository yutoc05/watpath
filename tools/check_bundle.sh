#!/bin/sh
# Xcode pre-build check: fail fast if the campus bundle is missing or stale.
# Deliberately does not run the compiler, so Xcode never depends on Python.
set -eu
cd "$(dirname "$0")/.."
manifest=build/CampusBundle/manifest.json
if [ ! -f "$manifest" ]; then
  echo "error: Campus bundle not found. Run 'make data'."
  exit 1
fi
expected=$(tools/source_hash.sh)
actual=$(sed -n 's/.*"sourceHash": *"\([0-9a-f]*\)".*/\1/p' "$manifest")
if [ "$expected" != "$actual" ]; then
  echo "error: Campus bundle is out of date with data/. Run 'make data'."
  exit 1
fi
