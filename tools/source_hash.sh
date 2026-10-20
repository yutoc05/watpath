#!/bin/sh
# Prints a hash of the map source data. The compiler stamps it into the bundle
# manifest and tools/check_bundle.sh compares against it, so both must use this.
set -eu
cd "$(dirname "$0")/.."
dirs=""
for dir in data/campus data/osm data/photos; do
  if [ -d "$dir" ]; then dirs="$dirs $dir"; fi
done
# shellcheck disable=SC2086
find $dirs -type f ! -name '.DS_Store' -print0 | LC_ALL=C sort -z | xargs -0 cat | shasum -a 256 | cut -d' ' -f1
