"""Builds ResMon as a Rainmeter skin package (.rmskin) to share: double-click it to install with Rainmeter.

    python -I rainmeter/package.py [--version 1.0] [--author NAME]
Output: dist/ResMon_<version>.rmskin

The package holds one build of the pages (pages.txt) for every HYTE Y70 screen size at the usual Windows scalings,
as configs ResMon\\<width>x<height>, because Rainmeter works in scaled pixels. Installing it loads the starter skin,
ResMon\\Start, which copies the starting settings into %APPDATA%\\Rainmeter\\ResMon (keeping any already there),
loads the build for the screen it finds and unloads itself (rainmeter/start.lua, setup.ps1).

None of your own data goes in: settings, weather places, game lists, art, history and caches come from the generic
starting files made here, and the built pages point at the data folder through Rainmeter's #SETTINGSPATH#.
The package is checked for your user name and places before it's written.
"""
import argparse
import getpass
import io
import json
import os
import re
import shutil
import struct
import sys
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, HERE)
import build_skin as bs  # noqa: E402

# (physical size, Windows scalings): the logical size is the physical size / scaling, rounded
SCREENS = [((1100, 3840), (100, 125, 150, 175, 200)),     # Y70 Touch (1st gen)
           ((688, 2560), (100, 125, 150)),                # Y70 Touch Infinite (2nd gen)
           ((682, 2560), (100, 125, 150))]                # Y70 Touch Infinite (3rd gen)
# the weather places offered on the settings page (weather.json "locations"); the first is the fallback when
# Windows' location service can't say where the PC is
CITIES = ["London", "New York", "Chicago", "Los Angeles", "Honolulu", "Mexico City", "São Paulo", "Buenos Aires",
          "Santiago", "Madrid", "Berlin", "Dubai", "Mumbai", "Singapore", "Tokyo", "Sydney", "Auckland"]
COORDS = {"London": (51.51, -0.13), "New York": (40.71, -74.01), "Chicago": (41.88, -87.63),
          "Los Angeles": (34.05, -118.24), "Honolulu": (21.31, -157.86), "Mexico City": (19.43, -99.13),
          "São Paulo": (-23.55, -46.63), "Buenos Aires": (-34.60, -58.38), "Santiago": (-33.45, -70.67),
          "Madrid": (40.42, -3.70), "Berlin": (52.52, 13.40), "Dubai": (25.20, 55.27), "Mumbai": (19.08, 72.88),
          "Singapore": (1.35, 103.82), "Tokyo": (35.68, 139.69), "Sydney": (-33.87, 151.21),
          "Auckland": (-36.85, 174.76)}
RUNTIME_FILES = ["settings.inc", "weather.json", "ignored-apps.txt", "known-games.txt"]   # copied by setup.ps1


def sizes():
    out = []
    for (w, h), scales in SCREENS:
        for s in scales:
            out.append((round(w * 100 / s), round(h * 100 / s)))
    return out


def pages():
    """pages.txt: the designs in swipe order and the default page."""
    lines = [l.strip() for l in open(os.path.join(ROOT, "pages.txt"), encoding="utf-8")
             if l.strip() and not l.strip().startswith("#")]
    designs = [os.path.join(ROOT, "screens", l) for l in lines if not re.match(r"default\s*=", l)]
    d = next((re.sub(r"^default\s*=\s*", "", l) for l in lines if re.match(r"default\s*=", l)), "")
    default = os.path.join(ROOT, "screens", d) if d else designs[0]
    return designs, default if default in designs else designs[0]


def starting_files(data):
    """The generic starting files the builder reads (and the package ships): no places or games of yours."""
    os.makedirs(data, exist_ok=True)
    c = CITIES[0]
    with open(os.path.join(data, "weather.json"), "w", encoding="utf-8", newline="\n") as fh:
        json.dump({"name": c, "latitude": COORDS[c][0], "longitude": COORDS[c][1], "refresh_minutes": 15,
                   "locations": [{"name": n, "latitude": COORDS[n][0], "longitude": COORDS[n][1]} for n in CITIES]},
                  fh, ensure_ascii=False, indent=2)
    # the auto-switch rules and the list of apps that are never games are generic: the project's own
    for f in ("autoswitch.json", "ignored-apps.txt"):
        if os.path.exists(os.path.join(ROOT, f)):
            shutil.copy(os.path.join(ROOT, f), os.path.join(data, f))


def start_skin(skins, builds, page):
    """ResMon\\Start: copies the starting files, loads the build for this screen, unloads itself (start.lua)."""
    res = os.path.join(skins, "@Resources")
    for f in ("start.lua", "setup.ps1"):
        shutil.copy(os.path.join(HERE, f), os.path.join(res, f))
    st = os.path.join(skins, "Start")
    os.makedirs(st, exist_ok=True)
    with open(os.path.join(st, "Start.ini"), "w", encoding="utf-16") as fh:
        fh.write(f"""; ResMon starter: loads the ResMon build for this PC's HYTE Y70 screen, then unloads itself.
; Load it again after changing the screen's scaling (Windows Settings > Display).
[Rainmeter]
Update=1000
OnRefreshAction=[!CommandMeasure mSetup "Run"]

[Metadata]
Name=ResMon starter
Information=Loads the ResMon build that fits this PC's HYTE Y70 screen.

[Variables]
Builds={"|".join(builds)}

[mSetup]
; copies the starting settings into %APPDATA%\\Rainmeter\\ResMon (keeps any already there)
Measure=Plugin
Plugin=RunCommand
Program=powershell.exe
Parameter=-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "#@#setup.ps1" -From "#@#defaults" -To "#SETTINGSPATH#ResMon"
State=Hide
Timeout=30000
FinishAction=[!CommandMeasure mStart "Start()"]

[mStart]
Measure=Script
ScriptFile=#@#start.lua
Builds=#Builds#
Page={page}
UpdateDivider=-1

[Status]
Meter=String
Text=Starting ResMon...
FontFace=Segoe UI
FontSize=12
FontColor=255,255,255
SolidColor=0,0,0,200
Padding=12,8,12,8
AntiAlias=1
""")


def rmskin(stage, path, author, version):
    """The .rmskin: a zip of RMSKIN.ini and Skins\\, followed by Rainmeter's 16-byte footer (the zip's size, a flags
    byte, "RMSKIN" and a zero byte)."""
    with open(os.path.join(stage, "RMSKIN.ini"), "w", encoding="utf-8", newline="\r\n") as fh:
        fh.write(f"""[rmskin]
Name=ResMon
Author={author}
Version={version}
MinimumRainmeter=4.5.0
MinimumWindows=10.0
LoadType=Skin
Load=ResMon\\Start\\Start.ini
""")
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
        for dirpath, _, files in os.walk(stage):
            for f in sorted(files):
                full = os.path.join(dirpath, f)
                z.write(full, os.path.relpath(full, stage).replace("\\", "/"))
    data = buf.getvalue()
    with open(path, "wb") as fh:
        fh.write(data + struct.pack("<Q", len(data)) + b"\x00RMSKIN\x00")


def personal(stage):
    """Text in the package that would give away whose PC built it: the user name, the project's own places."""
    needles = {getpass.getuser().lower(), os.path.expanduser("~").lower(), ROOT.lower()}
    try:
        w = json.load(open(os.path.join(ROOT, "weather.json"), encoding="utf-8"))
        own = [w.get("name", "")] + [p.get("name", "") for p in w.get("locations", [])]
        needles |= {n.lower() for n in own if n and n not in COORDS}
        if w.get("latitude") is not None:
            needles.add(f'{w["latitude"]}'.lower())
    except (OSError, ValueError):
        pass
    needles.discard("")
    hits = []
    for dirpath, _, files in os.walk(stage):
        for f in files:
            if f.lower().endswith((".png", ".jpg", ".exe")):
                continue
            raw = open(os.path.join(dirpath, f), "rb").read()
            text = (raw.decode("utf-16", "ignore") if raw[:2] in (b"\xff\xfe", b"\xfe\xff")
                    else raw.decode("utf-8", "ignore")).lower()
            hits += [f"{os.path.relpath(os.path.join(dirpath, f), stage)}: {n}" for n in needles if n in text]
    return hits


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="1.0")
    ap.add_argument("--author", default="ResMon")
    ap.add_argument("--sizes", help="only these sizes, e.g. 1100x3840,682x2560 (for testing)")
    a = ap.parse_args()

    dist = os.path.join(ROOT, "dist")
    stage = os.path.join(dist, "stage")
    shutil.rmtree(stage, ignore_errors=True)
    skins = os.path.join(stage, "Skins", "ResMon")
    data = os.path.join(dist, "data")          # what the builder reads; the runtime part ships in defaults
    shutil.rmtree(data, ignore_errors=True)
    starting_files(data)

    bs.PACKAGE, bs.DATA = True, data
    # the second clock starts on the first city (rather than the project's own choice)
    bs.SETTING_DEFAULTS = [(k, CITIES[0] if k == "AltCity" else v, n) for k, v, n in bs.SETTING_DEFAULTS]
    bs.init_data()
    designs, default = pages()
    bs.DEFAULT_PAGE = bs.page_name(default)

    want = sizes() if not a.sizes else [tuple(int(v) for v in s.split("x")) for s in a.sizes.split(",")]
    builds = []
    # the full-size Y70 last: the backdrop's starting picture comes from the last build
    for w, h in sorted(set(want), key=lambda s: (s != (1100, 3840), s), reverse=True):
        name = f"{w}x{h}"
        print(f"== {name}", flush=True)
        bs.build_pages(designs, (w, h), skins, name)
        builds.append(name)
    builds.reverse()

    defaults = os.path.join(skins, "@Resources", "defaults")
    os.makedirs(defaults, exist_ok=True)
    for f in RUNTIME_FILES:
        shutil.copy(os.path.join(data, f), os.path.join(defaults, f))
    start_skin(skins, builds, bs.DEFAULT_PAGE)

    hits = personal(stage)
    if hits:
        print("Not written: the package has personal data:\n  " + "\n  ".join(hits))
        sys.exit(1)
    out = os.path.join(dist, f"ResMon_{a.version}.rmskin")
    rmskin(stage, out, a.author, a.version)
    print(f"Wrote {out} ({os.path.getsize(out) / 1048576:.1f} MB, builds: {', '.join(builds)})")


if __name__ == "__main__":
    main()
