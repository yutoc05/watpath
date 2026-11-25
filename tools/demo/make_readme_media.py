#!/usr/bin/env python3
"""Makes the README's images: the designed banners and the feature clips.

The banners are pages in design/readme, drawn from the real campus data and from frames of
the feature recording, and rendered at twice their size by render.mjs in headless Chrome.
The clips are cut from that recording (record.py --test testFeatures) at the scenes
DemoTour marked, and set on the same stage as the banners. Everything lands in docs/media/readme.

    tools/demo/make_readme_media.py [--only banners|clips|<name> ...]

Needs build/CampusBundle (make data), build/demo/raw-features.mov with features.json and
recording-features.json, Node, Google Chrome and ffmpeg.
"""
import argparse
import json
import math
import os
import pathlib
import subprocess
import urllib.parse

REPO = pathlib.Path(__file__).resolve().parents[2]
TOOLS = REPO / "tools/demo"
DESIGN = REPO / "design/readme"
WORK = REPO / "build/readme"
MEDIA = REPO / "docs/media/readme"
DEMO = REPO / "build/demo"
DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"


def run(*args, **kwargs):
    subprocess.run([str(a) for a in args], check=True, **kwargs)


def ffmpeg(*args):
    run("ffmpeg", "-loglevel", "error", "-y", *args)


# MARK: - Data for the pages


def campus_data():
    """The campus in meters east and south of its origin, for the pages to draw."""
    bundle = json.loads((REPO / "build/CampusBundle/campus.json").read_text())
    inventory = json.loads((REPO / "data/campus/inventory.json").read_text())
    labels = {b["code"]: b["label"] for b in inventory["buildings"] if b.get("label")}
    origin = bundle["origin"]
    scale = math.cos(math.radians(origin["latitude"]))

    def xy(point):
        lon, lat = point
        return [round((lon - origin["longitude"]) * 111_320 * scale, 1), round((origin["latitude"] - lat) * 110_540, 1)]

    def line(points):
        return [xy(p) for p in points]

    buildings = []
    for building in bundle["buildings"]:
        rings = [line(part["outline"]) for part in building["parts"]]
        holes = [line(hole) for part in building["parts"] for hole in part.get("holes", [])]
        outline = max(rings, key=len)
        center = xy(labels[building["code"]]) if building["code"] in labels else [
            round(sum(p[0] for p in outline) / len(outline), 1), round(sum(p[1] for p in outline) / len(outline), 1)]
        buildings.append({"code": building["code"], "name": building["name"], "rings": rings, "holes": holes, "label": center})
    connections = [
        {"kind": c["kind"], "name": c["name"], "paths": [line(p["points"]) for p in c["paths"]]}
        for c in bundle["connections"] if c["kind"] in ("bridge", "tunnel")
    ]
    corridors = [line(c) for c in bundle["corridors"]]
    doors = [xy(d["coordinate"]) for d in bundle["doors"]]
    stats = {
        "buildings": len(bundle["buildings"]),
        "doors": len(bundle["doors"]),
        "bridges": sum(c["kind"] == "bridge" for c in bundle["connections"]),
        "tunnels": sum(c["kind"] == "tunnel" for c in bundle["connections"]),
        "corridorMeters": round(sum(math.dist(a, b) for c in corridors for a, b in zip(c, c[1:]))),
    }
    graph = json.loads((REPO / "build/CampusBundle/graph.json").read_text())
    stats["nodes"], stats["edges"] = len(graph["nodes"]), len(graph["edges"])
    return {"buildings": buildings, "corridors": corridors, "connections": connections, "doors": doors,
            "stats": stats, "project": {"origin": origin, "scale": scale}}


def route_data():
    """The routes from SLC to E5, found by the real router (RoutingTests/ReadmeRoutes)."""
    out = WORK / "routes.json"
    env = dict(os.environ, README_ROUTES=str(out), DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", DEVELOPER_DIR))
    run("swift", "test", "--package-path", REPO / "Packages/WatPathKit", "--filter", "ReadmeRoutes", "--quiet", env=env)
    return json.loads(out.read_text())


def write_data():
    WORK.mkdir(parents=True, exist_ok=True)
    campus = campus_data()
    origin, scale = campus["project"]["origin"], campus["project"]["scale"]
    routes = route_data()
    for route in routes:
        for span in route["spans"]:
            span["points"] = [[round((lon - origin["longitude"]) * 111_320 * scale, 1), round((origin["latitude"] - lat) * 110_540, 1)]
                              for lon, lat in span["points"]]
    campus["routes"] = routes
    (WORK / "data.js").write_text("window.WATPATH = " + json.dumps(campus, separators=(",", ":")) + ";\n")
    print(f"{WORK / 'data.js'}: {campus['stats']}")


# MARK: - Feature clips

# Where the recording goes on clip.html's stage (its .phone, inside the bezel).
SCREEN = dict(x=72, y=28, width=260, height=564, radius=37)
STAGE = (860, 620)
CLIP_FPS = 15
STEP_FADE = 0.25

# Each clip is a list of pieces of the recording, (from scene, seconds after it, to scene,
# seconds after it, speed), played one after another, and the step on the stage that's lit
# from a moment of the recording on: (scene, seconds after it, step). Pieces that meet
# where the screen is still join without a visible cut.
CLIPS = {
    "xray": {
        "pieces": [("xray", 0.4, "xray", 3.4, 1), ("xray", 4.9, "xray", 7.1, 1), ("xray", 8.7, "xrayEnd", -3.0, 1)],
        "steps": [("xray", 0, 0), ("xray", 1.8, 1), ("xray", 5.6, 0), ("xray", 9.3, 1), ("xray", 10.4, 2), ("xray", 15.0, 0)],
    },
    "search": {
        "pieces": [("search", 0.1, "search", 3.7, 1), ("search", 3.7, "search", 12.0, 2), ("search", 12.0, "searchEnd", -1.4, 1)],
        "steps": [("search", 0, 0), ("search", 3.7, 1), ("search", 13.2, 2)],
    },
    "directions": {
        "pieces": [("routes", 0.4, "routes", 3.6, 1), ("routes", 4.6, "routes", 11.6, 1.75), ("routes", 11.6, "routesEnd", -1.6, 1)],
        "steps": [("routes", 0, 0), ("routes", 12.0, 1), ("routes", 16.0, 2)],
    },
    "navigation": {
        "pieces": [("navigate", 1.55, "navigate", 10.4, 1.25), ("navigate", 10.4, "outdoors", 1.4, 2.5), ("outdoors", 1.4, "arrived", 1.0, 1.4)],
        "steps": [("navigate", 0, 0), ("navigate", 5.8, 1), ("navigate", 10.4, 0), ("outdoors", 1.4, 2)],
    },
}


def render(url, out, *extra):
    run("node", TOOLS / "render.mjs", url, out, *extra)


def page(name, **query):
    url = (DESIGN / name).as_uri()
    return f"{url}?{urllib.parse.urlencode(query)}" if query else url


def duration(path):
    return float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout)


def feature_times():
    started = json.loads((DEMO / "recording-features.json").read_text())["started"]
    return {scene["name"]: scene["time"] - started for scene in json.loads((DEMO / "features.json").read_text())}


def steady():
    """The feature recording at the stage's screen size and a steady frame rate, on its true
    clock (see make_video.py's steady: +igndts keeps the Simulator's presentation times)."""
    clip = WORK / "steady.mp4"
    ffmpeg("-fflags", "+igndts", "-i", DEMO / "raw-features.mov",
           "-vf", f"fps=30,scale={SCREEN['width']}:{SCREEN['height']}:flags=lanczos,format=yuv420p",
           "-c:v", "libx264", "-crf", "8", "-preset", "fast", clip)
    return clip


def screen_mask():
    mask = WORK / "screen-mask.png"
    render("data:text/html," + urllib.parse.quote(
        f'<body style="margin:0;background:#000"><div style="width:{SCREEN["width"]}px;height:{SCREEN["height"]}px;'
        f'border-radius:{SCREEN["radius"]}px;background:#fff"></div></body>'),
        mask, "--size", f"{SCREEN['width']}x{SCREEN['height']}")
    return mask


def cut(clip, name, spec, times):
    """The clip's pieces back to back, and when each step is lit, in the cut's seconds."""
    pieces = [(times[a] + da, times[b] + db, speed) for a, da, b, db, speed in spec["pieces"]]
    marks = sorted((times[scene] + offset, step) for scene, offset, step in spec["steps"])
    trims, spans, clock = [], [], 0.0
    for i, (a, b, speed) in enumerate(pieces):
        trims.append(f"[in{i}]trim=start={a:.3f}:end={b:.3f},setpts=(PTS-STARTPTS)/{speed}[s{i}]")
        # The steps lit during this piece, mapped onto the cut's clock.
        edges = sorted({a, b, *(t for t, _ in marks if a < t < b)})
        for start, end in zip(edges, edges[1:]):
            step = max((m for m in marks if m[0] <= start), default=marks[0])[1]
            out = (clock + (start - a) / speed, clock + (end - a) / speed)
            if spans and spans[-1][0] == step:
                spans[-1][2] = out[1]
            else:
                spans.append([step, *out])
        clock += (b - a) / speed
    branches = "".join(f"[in{i}]" for i in range(len(pieces)))
    joined = "".join(f"[s{i}]" for i in range(len(pieces)))
    graph = f"[0:v]split={len(pieces)}{branches};" + ";".join(trims) + f";{joined}concat=n={len(pieces)}:v=1:a=0,fps=30,format=yuv420p[out]"
    phone = WORK / f"phone-{name}.mp4"
    ffmpeg("-i", clip, "-filter_complex", graph, "-map", "[out]", "-c:v", "libx264", "-crf", "8", "-preset", "fast", phone)
    return phone, spans


def make_clip(name, spec, clip, mask, times):
    phone, spans = cut(clip, name, spec, times)
    length = duration(phone)
    stages = {}
    for step in sorted({s for s, _, _ in spans}):
        stages[step] = WORK / f"stage-{name}-{step}.png"
        render(page("clip.html", clip=name, step=step), stages[step], "--size", f"{STAGE[0]}x{STAGE[1]}")
    inputs = ["-i", phone, "-loop", "1", "-t", f"{length:.3f}", "-i", mask]
    graph = ["[1:v]format=gray[mask]", "[0:v][mask]alphamerge[screen]"]
    base = 2  # after the phone and the mask
    inputs += ["-loop", "1", "-framerate", "30", "-t", f"{length:.3f}", "-i", stages[spans[0][0]]]
    last = f"{base}:v"
    for i, (step, start, end) in enumerate(spans[1:], 1):
        inputs += ["-loop", "1", "-framerate", "30", "-t", f"{length:.3f}", "-i", stages[step]]
        graph.append(f"[{base + i}:v]format=rgba,fade=t=in:st={start:.3f}:d={STEP_FADE}:alpha=1[st{i}]")
        graph.append(f"[{last}][st{i}]overlay=0:0:enable='between(t,{start:.3f},{end:.3f})'[bg{i}]")
        last = f"bg{i}"
    graph.append(f"[{last}][screen]overlay={SCREEN['x']}:{SCREEN['y']}:shortest=1,fps={CLIP_FPS},split[a][b]")
    graph.append("[a]palettegen=max_colors=256:stats_mode=full[p]")
    graph.append("[b][p]paletteuse=dither=bayer:bayer_scale=3:diff_mode=rectangle[out]")
    gif = MEDIA / f"{name}.gif"
    gif.parent.mkdir(parents=True, exist_ok=True)
    # -t: the looped stills would otherwise run on past the end of the recording.
    ffmpeg(*inputs, "-filter_complex", ";".join(graph), "-map", "[out]", "-t", f"{length:.3f}", "-loop", "0", gif)
    print(f"{gif}: {length:.1f} s, {gif.stat().st_size / 1e6:.1f} MB")


def make_clips(only=None):
    WORK.mkdir(parents=True, exist_ok=True)
    times = feature_times()
    clip, mask = steady(), screen_mask()
    for name, spec in CLIPS.items():
        if only is None or name in only:
            make_clip(name, spec, clip, mask, times)


# MARK: - Screenshots for the banners

# Moments of the feature recording the banners show, as (scene, seconds after it).
SHOTS = {
    "street-3d": ("xray", 1.0),
    "path-3d": ("xray", 4.2),
    "search-typo": ("search", 11.6),
    "place-card": ("searchEnd", -2.2),
    "routes-all": ("routesEnd", -4.2),
    "nav-start": ("navigate", 2.8),
    "nav-indoor": ("navigate", 7.3),
    "nav-outdoor": ("outdoors", 6.0),
    "nav-arrived": ("arrived", 1.0),
}


def shots(times):
    """Full-size frames of the feature recording, for the banners to frame in a phone."""
    folder = WORK / "shots"
    folder.mkdir(parents=True, exist_ok=True)
    # Seeking in the raw recording lands on the wrong frames, so seek in a steady copy.
    full = WORK / "steady-full.mp4"
    ffmpeg("-fflags", "+igndts", "-i", DEMO / "raw-features.mov", "-vf", "fps=30,format=yuv444p",
           "-c:v", "libx264", "-crf", "6", "-preset", "fast", full)
    for name, (scene, offset) in SHOTS.items():
        ffmpeg("-ss", f"{times[scene] + offset:.3f}", "-i", full, "-frames:v", "1", folder / f"{name}.png")
    print(f"{len(SHOTS)} screenshots in {folder}")


# MARK: - Banners

# Each banner's page in design/readme and its size in CSS pixels; it's drawn at twice that.
BANNERS = {
    "hero": ("hero.html", 860, 500),
    "network": ("network.html", 860, 540),
    "route-choices": ("route-choices.html", 860, 560),
    "navigation-guide": ("navigation-guide.html", 860, 560),
    "pipeline": ("pipeline.html", 860, 540),
    "performance": ("performance.html", 860, 310),
}


def make_banners(only=None):
    MEDIA.mkdir(parents=True, exist_ok=True)
    for name, (html, width, height) in BANNERS.items():
        if only is None or name in only:
            out = MEDIA / f"{name}.png"
            render(page(html), out, "--size", f"{width}x{height}", "--scale", "2")
            print(f"{out}: {out.stat().st_size / 1e6:.1f} MB")


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", nargs="+", help="banners, clips, or the names of single banners and clips")
    args = parser.parse_args()
    only = set(args.only or [])
    pick = lambda group, names: None if not only or group in only else (only & set(names)) or set()
    times = feature_times()
    banners, clips = pick("banners", BANNERS), pick("clips", CLIPS)
    if banners != set():
        write_data()
        shots(times)
        make_banners(banners)
    if clips != set():
        make_clips(clips)


if __name__ == "__main__":
    main()
