#!/usr/bin/env python3
"""Records the demo walkthrough in the Simulator.

Builds the app and its UI tests, tidies the Simulator (full battery, light mode,
location allowed), then plays AppUITests/DemoTour.swift while `simctl` records the screen.
Leaves build/demo/raw.mov, plus scenes.json (when each scene started) and recording.json
(when the recording started), which make_video.py turns into the finished video.

    tools/demo/record.py [--simulator "iPhone 17"]
"""
import argparse
import json
import os
import pathlib
import signal
import subprocess
import sys
import time

REPO = pathlib.Path(__file__).resolve().parents[2]
OUT = REPO / "build/demo"
BUNDLE_ID = "ca.yutochau.watpath"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def simulator_id(name):
    """The newest iOS runtime's simulator with this name."""
    listing = json.loads(subprocess.run(
        ["xcrun", "simctl", "list", "devices", "available", "--json"], check=True, capture_output=True, text=True
    ).stdout)
    matches = [
        (runtime, device["udid"])
        for runtime, devices in listing["devices"].items() if "iOS" in runtime
        for device in devices if device["name"] == name
    ]
    if not matches:
        sys.exit(f"No simulator named {name!r}")
    return max(matches)[1]


def prepare(udid):
    subprocess.run(["xcrun", "simctl", "boot", udid], capture_output=True)  # fine if already booted
    run("xcrun", "simctl", "bootstatus", udid, "-b", stdout=subprocess.DEVNULL)
    run("xcrun", "simctl", "ui", udid, "appearance", "light")
    # The real time, not 9:41, so the clock agrees with the arrival time on the navigation card.
    clock = time.strftime("%-I:%M")
    run("xcrun", "simctl", "status_bar", udid, "override", "--time", clock, "--dataNetwork", "wifi",
        "--wifiMode", "active", "--wifiBars", "3", "--cellularMode", "active", "--cellularBars", "4",
        "--operatorName", "", "--batteryState", "charged", "--batteryLevel", "100")
    run("xcrun", "simctl", "privacy", udid, "grant", "location", BUNDLE_ID)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--simulator", default="iPhone 17")
    parser.add_argument("--skip-build", action="store_true")
    args = parser.parse_args()
    os.environ.setdefault("DEVELOPER_DIR", DEVELOPER_DIR)
    udid = simulator_id(args.simulator)
    destination = f"id={udid}"
    xcodebuild = ["xcodebuild", "-project", str(REPO / "WatPath.xcodeproj"), "-scheme", "WatPath",
                  "-derivedDataPath", str(REPO / "build/DerivedData"), "-destination", destination]
    if not args.skip_build:
        run("xcodegen", "generate", "--quiet", cwd=REPO)
        run(*xcodebuild, "build-for-testing", "-quiet")

    prepare(udid)
    OUT.mkdir(parents=True, exist_ok=True)
    (OUT / "scenes.json").unlink(missing_ok=True)
    raw = OUT / "raw.mov"
    recorder = subprocess.Popen(
        ["xcrun", "simctl", "io", udid, "recordVideo", "--codec=h264", "--force", str(raw)],
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
    )
    for line in recorder.stdout:
        if "Recording started" in line:
            break
    started = time.time()
    try:
        env = dict(os.environ, TEST_RUNNER_DEMO_DIR=str(OUT))
        result = subprocess.run(
            [*xcodebuild, "test-without-building", "-only-testing:WatPathUITests/DemoTour/testTour", "-quiet"], env=env
        )
    finally:
        recorder.send_signal(signal.SIGINT)
        recorder.wait()
    (OUT / "recording.json").write_text(json.dumps({"started": started, "simulator": args.simulator}, indent=2))
    if result.returncode != 0:
        sys.exit("The tour failed; see the xcodebuild output above.")
    print(f"Recorded {raw}")


if __name__ == "__main__":
    main()
