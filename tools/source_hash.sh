#!/bin/sh
# Prints a hash of the map source data. The compiler stamps it into the bundle
# manifest and tools/check_bundle.sh compares against it, so both must use this.
set -eu
cd "$(dirname "$0")/.."
find data/campus data/osm -type f \( -name '*.json' -o -name '*.geojson' \) | LC_ALL=C sort | xargs cat | shasum -a 256 | cut -d' ' -f1
