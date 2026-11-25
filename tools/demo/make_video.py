#!/usr/bin/env python3
"""Turns the walkthrough that record.py captured into the demo video.

Cuts the Simulator recording at the scenes DemoTour marked, sets it in a phone frame on
the WatPath stage with a caption for each feature, and opens and closes on the intro
(intro.html). Pages are drawn by render.mjs in headless Chrome; ffmpeg does the rest.

    tools/demo/make_video.py [--tagline "Every bridge. Every tunnel."] [--out docs/media/demo.mp4] [--gif docs/media/demo.gif]

The GIF is the README's preview: GitHub plays animated images inline, but not videos
committed to the repository.
"""
import argparse
import json
import pathlib
import shutil
import subprocess
import urllib.parse

REPO = pathlib.Path(__file__).resolve().parents[2]
TOOLS = REPO / "tools/demo"
WORK = REPO / "build/demo"
FPS = 60
SIZE = (1920, 1080)
# Where the screen sits on stage.html, which draws the frame around it.
PHONE = dict(x=430, y=50, width=450, height=980, radius=68)
FADE = 0.35

# (from scene, seconds after it, to scene, seconds after it, caption)
SEGMENTS = [
    ("street", -2.0, "search", 0.0, "street"),
    ("search", 0.0, "card", 0.0, "search"),
    ("card", 0.0, "pathMap", 0.0, "search"),
    ("pathMap", 0.0, "directions", 0.0, "path"),
    ("directions", 0.0, "pinPlaced", 0.0, "directions"),
    ("pinPlaced", 0.0, "routes", 0.0, "directions"),
    ("routes", 0.0, "navigation", 0.0, "routes"),
    ("navigation", 0.0, "arrived", 2.0, "navigation"),
    # Tapping Done waits for the app to settle, so skip to just before the tap lands.
    ("done", -0.8, "done", 1.4, "navigation"),
]
CAPTIONS = {
    "street": ("Street Map", "Every building and entrance on campus."),
    "search": ("Search", "Look up any building by its code or name."),
    "path": ("Path Map", "See through to every corridor, bridge and tunnel."),
    "directions": ("Directions", "Drop a pin where you are, inside any building."),
    "routes": ("Routes", "Take the fastest way, or the one that stays inside."),
    "navigation": ("Navigation", "Drag to walk the route. Swipe to look around."),
}
# The tour waits on the app between steps, so stretches where nothing moves are cut down
# to HOLD seconds, or longer where there's something to read: a stillness that takes in
# one of these scenes or starts within a second of it. LEAD is kept before the next move.
HOLD = 1.1
LONGER_HOLDS = {"street": 2.6, "card": 2.0, "routes": 2.2, "arrived": 1.6}
LEAD = 0.3
INTRO_HOLD = 0.6
OUTRO = 3.0
CROSSFADE = 0.5


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def render(url, out, *extra):
    run("node", TOOLS / "render.mjs", url, out, *extra)


def page(name, **query):
    url = (TOOLS / name).as_uri()
    return f"{url}?{urllib.parse.urlencode(query)}" if query else url


def ffmpeg(*args):
    run("ffmpeg", "-loglevel", "error", "-y", *args)


def duration(path):
    return float(subprocess.run(
        ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "csv=p=0", str(path)],
        check=True, capture_output=True, text=True,
    ).stdout)


def scene_times():
    started = json.loads((WORK / "recording.json").read_text())["started"]
    return {scene["name"]: scene["time"] - started for scene in json.loads((WORK / "scenes.json").read_text())}


def steady():
    """The recording at the phone's size and a steady frame rate, on its true clock.

    The Simulator writes a frame only when the screen changes, and its presentation times
    are slightly out of order, so ffmpeg would otherwise fall back on decode times, which
    run about four seconds behind. +igndts makes it keep the presentation times."""
    clip = WORK / "steady.mp4"
    ffmpeg("-fflags", "+igndts", "-i", WORK / "raw.mov",
           "-vf", f"fps={FPS},scale={PHONE['width']}:{PHONE['height']}:flags=lanczos,format=yuv420p",
           "-c:v", "libx264", "-crf", "10", "-preset", "fast", clip)
    return clip


def stills(clip, start, end):
    """Stretches between start and end, in the clip's seconds, where nothing moves."""
    log = subprocess.run(
        ["ffmpeg", "-hide_banner", "-i", str(clip), "-vf", "freezedetect=n=0.002:d=0.8", "-map", "0:v", "-f", "null", "-"],
        check=True, capture_output=True, text=True,
    ).stderr
    marks = [float(line.split(":")[-1]) for line in log.splitlines() if "freeze_start" in line or "freeze_end" in line]
    if len(marks) % 2:
        marks.append(duration(clip))
    return [(max(a, start), min(b, end)) for a, b in zip(marks[::2], marks[1::2]) if b > start and a < end]


def cut_phone(times):
    """The recording's scenes back to back, at the phone's size, and each caption's span."""
    clip = steady()
    ranges = [(times[a] + da, times[b] + db, caption) for a, da, b, db, caption in SEGMENTS]
    removed = []
    for still_start, still_end in stills(clip, ranges[0][0], ranges[-1][1]):
        hold = next((value for scene, value in LONGER_HOLDS.items()
                     if still_start <= times[scene] <= still_end or 0 <= still_start - times[scene] < 1.0), HOLD)
        if still_end - still_start > hold:
            removed.append((still_start + hold - LEAD, still_end - LEAD))
    pieces = []
    for a, b, caption in ranges:
        for cut_start, cut_end in removed:
            if cut_end <= a or cut_start >= b:
                continue
            if cut_start > a:
                pieces.append((a, cut_start, caption))
            a = max(a, cut_end)
        if b - a > 1 / FPS:
            pieces.append((a, b, caption))
    trims, spans, clock = [], [], 0.0
    for i, (a, b, caption) in enumerate(pieces):
        trims.append(f"[in{i}]trim=start={a:.3f}:end={b:.3f},setpts=PTS-STARTPTS[s{i}]")
        if spans and spans[-1][0] == caption:
            spans[-1][2] = clock + (b - a)
        else:
            spans.append([caption, clock, clock + (b - a)])
        clock += b - a
    branches = "".join(f"[in{i}]" for i in range(len(pieces)))
    joined = "".join(f"[s{i}]" for i in range(len(pieces)))
    graph = f"[0:v]split={len(pieces)}{branches};" + ";".join(trims) + f";{joined}concat=n={len(pieces)}:v=1:a=0,format=yuv420p[out]"
    phone = WORK / "phone.mp4"
    ffmpeg("-i", clip, "-filter_complex", graph, "-map", "[out]",
           "-c:v", "libx264", "-crf", "12", "-preset", "medium", phone)
    return phone, spans


def stage_and_captions(spans):
    stage = WORK / "stage.png"
    render(page("stage.html"), stage)
    mask = WORK / "mask.png"
    render(
        "data:text/html," + urllib.parse.quote(
            f'<body style="margin:0;background:#000"><div style="width:{PHONE["width"]}px;height:{PHONE["height"]}px;'
            f'border-radius:{PHONE["radius"]}px;background:#fff"></div></body>'),
        mask, "--size", f"{PHONE['width']}x{PHONE['height']}",
    )
    captions = {}
    for key in {span[0] for span in spans}:
        title, body = CAPTIONS[key]
        captions[key] = WORK / f"caption-{key}.png"
        render(page("caption.html", title=title, body=body), captions[key], "--transparent")
    return stage, mask, captions


def compose_main(phone, spans, stage, mask, captions):
    length = duration(phone)
    inputs = ["-loop", "1", "-t", f"{length:.3f}", "-i", stage, "-i", phone,
              "-loop", "1", "-t", f"{length:.3f}", "-i", mask]
    graph = [f"[2:v]format=gray[mask]", f"[1:v][mask]alphamerge[screen]",
             f"[0:v][screen]overlay={PHONE['x']}:{PHONE['y']}:shortest=1[v0]"]
    for i, (key, start, end) in enumerate(spans):
        inputs += ["-loop", "1", "-t", f"{length:.3f}", "-i", captions[key]]
        fade_in = max(start, 0)
        graph.append(
            f"[{3 + i}:v]format=rgba,fade=t=in:st={fade_in:.3f}:d={FADE}:alpha=1,"
            f"fade=t=out:st={end - FADE:.3f}:d={FADE}:alpha=1[c{i}]"
        )
        graph.append(f"[v{i}][c{i}]overlay=0:0:enable='between(t,{start:.3f},{end:.3f})'[v{i + 1}]")
    graph.append(f"[v{len(spans)}]fps={FPS},format=yuv420p[out]")
    main = WORK / "main.mp4"
    ffmpeg(*inputs, "-filter_complex", ";".join(graph), "-map", "[out]",
           "-c:v", "libx264", "-crf", "12", "-preset", "medium", main)
    return main


def intro_and_outro(tagline):
    frames = WORK / "intro"
    shutil.rmtree(frames, ignore_errors=True)
    render(page("intro.html", tagline=tagline), frames, "--frames", FPS)
    last = sorted(frames.glob("frame-*.png"))[-1]
    intro = WORK / "intro.mp4"
    ffmpeg("-framerate", FPS, "-i", frames / "frame-%04d.png",
           "-vf", f"tpad=stop_mode=clone:stop_duration={INTRO_HOLD},format=yuv420p",
           "-c:v", "libx264", "-crf", "12", "-preset", "medium", intro)
    outro = WORK / "outro.mp4"
    ffmpeg("-loop", "1", "-framerate", FPS, "-t", OUTRO, "-i", last,
           "-vf", "format=yuv420p", "-c:v", "libx264", "-crf", "12", "-preset", "medium", outro)
    return intro, outro


def finish(intro, main, outro, out):
    a, b = duration(intro), duration(main)
    graph = (
        f"[0:v]settb=AVTB,fps={FPS}[i];[1:v]settb=AVTB,fps={FPS}[m];[2:v]settb=AVTB,fps={FPS}[o];"
        f"[i][m]xfade=transition=fade:duration={CROSSFADE}:offset={a - CROSSFADE:.3f}[im];"
        f"[im][o]xfade=transition=fade:duration={CROSSFADE}:offset={a + b - 2 * CROSSFADE:.3f},format=yuv420p[out]"
    )
    out.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg("-i", intro, "-i", main, "-i", outro, "-filter_complex", graph, "-map", "[out]",
           "-c:v", "libx264", "-preset", "slow", "-crf", "24", "-profile:v", "high", "-pix_fmt", "yuv420p",
           "-movflags", "+faststart", "-an", out)


def make_gif(video, gif):
    """A 12 fps, 960-wide copy that plays inline in the README."""
    gif.parent.mkdir(parents=True, exist_ok=True)
    ffmpeg("-i", video, "-vf", "fps=12,scale=960:-1:flags=lanczos,split[a][b];"
           "[a]palettegen=max_colors=192:stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=4:diff_mode=rectangle",
           "-loop", "0", gif)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tagline", default="Every bridge. Every tunnel.")
    parser.add_argument("--out", type=pathlib.Path, default=WORK / "watpath-demo.mp4")
    parser.add_argument("--gif", type=pathlib.Path, help="also write the README's animated preview here")
    args = parser.parse_args()
    phone, spans = cut_phone(scene_times())
    stage, mask, captions = stage_and_captions(spans)
    main_clip = compose_main(phone, spans, stage, mask, captions)
    intro, outro = intro_and_outro(args.tagline)
    finish(intro, main_clip, outro, args.out.resolve())
    print(f"{args.out}: {duration(args.out):.1f} s, {args.out.stat().st_size / 1e6:.1f} MB")
    if args.gif:
        make_gif(args.out.resolve(), args.gif.resolve())
        print(f"{args.gif}: {args.gif.stat().st_size / 1e6:.1f} MB")


if __name__ == "__main__":
    main()
