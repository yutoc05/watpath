#!/bin/sh
# Build WatPath and launch it, streaming the app's console to this terminal.
#   tools/run.sh simulator ["iPhone 17"] [-- launch arguments]
#   tools/run.sh device [-- launch arguments]
# Example: tools/run.sh device -- -autoSpike
set -eu
cd "$(dirname "$0")/.."
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
BUNDLE_ID=ca.yutochau.watpath
DERIVED=build/DerivedData

target=${1:?usage: tools/run.sh simulator|device [name] [-- launch arguments]}
shift
name=""
if [ $# -gt 0 ] && [ "$1" != "--" ]; then name=$1; shift; fi
if [ "${1:-}" = "--" ]; then shift; fi

case "$target" in
  simulator)
    name=${name:-iPhone 17}
    xcodebuild -project WatPath.xcodeproj -scheme WatPath -configuration Debug \
      -derivedDataPath "$DERIVED" -destination "platform=iOS Simulator,name=$name" build -quiet
    xcrun simctl boot "$name" 2>/dev/null || true
    open -b com.apple.iphonesimulator 2>/dev/null || true  # optional: simctl works headless
    xcrun simctl install "$name" "$DERIVED/Build/Products/Debug-iphonesimulator/WatPath.app"
    exec xcrun simctl launch --console-pty --terminate-running-process "$name" "$BUNDLE_ID" "$@"
    ;;
  device)
    if [ ! -f Config/Local.xcconfig ]; then
      echo "error: Config/Local.xcconfig is missing. It sets DEVELOPMENT_TEAM for signing (see Config/Local.xcconfig.example)." >&2
      exit 1
    fi
    devices=$(mktemp)
    xcrun devicectl list devices --json-output "$devices" >/dev/null
    udid=$(python3 - "$devices" <<'EOF'
import json, sys
for device in json.load(open(sys.argv[1]))["result"]["devices"]:
    hardware = device.get("hardwareProperties", {})
    if hardware.get("platform") == "iOS" and hardware.get("reality") == "physical" \
            and device.get("connectionProperties", {}).get("tunnelState") != "unavailable":
        print(hardware["udid"])
        break
EOF
)
    rm -f "$devices"
    if [ -z "$udid" ]; then echo "error: no connected iPhone found" >&2; exit 1; fi
    xcodebuild -project WatPath.xcodeproj -scheme WatPath -configuration Debug \
      -derivedDataPath "$DERIVED" -destination "id=$udid" \
      -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
    xcrun devicectl device install app --device "$udid" "$DERIVED/Build/Products/Debug-iphoneos/WatPath.app"
    # The '--' stops devicectl from parsing app arguments like -autoSpike as its own flags.
    exec xcrun devicectl device process launch --device "$udid" --console --terminate-existing "$BUNDLE_ID" -- "$@"
    ;;
  *)
    echo "usage: tools/run.sh simulator|device [name] [-- launch arguments]" >&2
    exit 2
    ;;
esac
