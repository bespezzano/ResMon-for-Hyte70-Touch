"""Builds a Rainmeter skin from a ResMon screen design (screens/*.html).

Like the lconnect-screen-template exporter: headless Chrome captures the static art as one background
image (lc-live.js ?mode=geom hides live values and draws meters empty) plus the geometry of every live
slot, and each slot becomes a native Rainmeter meter:
  text  -> String meter (units that follow a growing value are chained with X=..R)
  arc   -> pre-rendered lit-gradient ring + a track-coloured cover arc and a round end dot (Shape)
  bar   -> Bar meter revealing a pre-rendered lit bar image
  chart -> Histogram (area) + Line meters
Sensor values come from HWiNFO's gadget registry export. A Lua script maps HWiNFO labels to registry
indexes every update, so adding or reordering HWiNFO sensors doesn't break the skin.

    python -I rainmeter/build_skin.py [screens/home.html]
Output: rainmeter/ResMon/<DesignName>/ (copied to Rainmeter's Skins folder by install-skin.ps1).
"""
import json
import colorsys
import math
import os
import re
import shutil
import struct
import subprocess
import sys
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
DEFAULT_PAGE = ""    # page shown when Rainmeter starts (--default); game.lua switches to it
# Your data (settings, game lists, weather places, logs, history). A normal build reads and keeps it in the project
# folder. A package build (rainmeter/package.py, PACKAGE = True) reads the package's starting files from DATA and
# makes the skin keep them in Rainmeter's settings folder, %APPDATA%\Rainmeter\ResMon (DATA_RT), where the starter
# skin copies them on first run.
PACKAGE = False
DATA = ROOT
DATA_RT = "#SETTINGSPATH#ResMon\\"


def data_src(name):
    """A data file as the builder reads it."""
    return os.path.join(DATA, name)


def rt(name):
    """A data file as the skin uses it at run time."""
    return DATA_RT + name if PACKAGE else os.path.join(ROOT, name)


def data_dir_rt():
    """The folder the settings page's Open button shows."""
    return DATA_RT.rstrip("\\") if PACKAGE else ROOT
sys.path.insert(0, HERE)
from sensors import LABELS  # noqa: E402  (HWiNFO label candidates per sensor key)

CHROME = next(p for p in [r"C:\Program Files\Google\Chrome\Application\chrome.exe",
                          r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"] if os.path.exists(p))
PT = 0.75            # Rainmeter FontSize is in points (96 dpi): px * 0.75
TEXT_DY = 0          # vertical calibration of String meters vs Chrome's text box, px per 100px of font size
MAX = {"CPUTEMP": 110, "HDDTEMP": 110, "GPUTEMP": 100, "CPUTEMP_F": 230, "GPUTEMP_F": 230,
       "UPSPEED": 100, "DOWNSPEED": 100}
DEC = {"CPUCLOCK_G": 2, "GPUCLOCK_G": 2, "RAM_GB": 1, "RAMTOTAL_GB": 1, "RAMVALID_GB": 1}
DERIVED = {"CPUCLOCK_G": ("CPUCLOCK", "/1000"), "GPUCLOCK_G": ("GPUCLOCK", "/1000"),
           "CPUTEMP_F": ("CPUTEMP", "*9/5+32"), "GPUTEMP_F": ("GPUTEMP", "*9/5+32")}
MEM = {"RAM_GB": "mMemUsed/1073741824", "RAMTOTAL_GB": "mMemTotal/1073741824",
       "RAMVALID_GB": "(mMemTotal-mMemUsed)/1073741824"}
TIMEFMT = {("TIME", "h:m:s"): "%H:%M:%S", ("TIME", "h:m"): "%H:%M", ("TIME", "h_24"): "%H",
           ("TIME", "h_12"): "%I", ("TIME", "m"): "%M", ("TIME", "s"): "%S", ("APM", ""): "%p",
           ("DATE", "Y-M-D"): "%Y-%m-%d", ("DATE", "Y"): "%Y", ("DATE", "M"): "%m", ("DATE", "D"): "%d",
           ("DATE", "M_en"): "%b", ("DAY", "Day_en"): "%a", ("DAY", "Num"): "%w",
           ("DATE", "D_num"): "%#d", ("DATE", "M_full"): "%B", ("DAY", "Day_full"): "%A"}
# the 12-hour version of each 24-hour time format (settings: Clock12); %#I is the hour without a leading zero
APM_DY = 0.8          # AM/PM's top below the time's top, as a share of the difference in their sizes (baselines meet)
TIME12 = {"%H:%M:%S": "%#I:%M:%S", "%H:%M": "%#I:%M", "%H": "%#I"}
WX_ORDER = ["clear-day", "clear-night", "partly-day", "partly-night", "cloudy", "fog", "drizzle", "rain", "snow", "thunder"]
LABEL_SLOTS = 64


# ---------------------------------------------------------------- helpers
def rgba(c, alpha=255):
    """CSS colour (#RGB[A], #RRGGBB[AA], rgb()/rgba()) -> (r,g,b,a)."""
    c = c.strip()
    if c.startswith("#"):
        h = c[1:]
        if len(h) in (3, 4):
            h = "".join(ch * 2 for ch in h)
        v = [int(h[i:i + 2], 16) for i in range(0, len(h), 2)]
        return tuple(v[:3]) + ((v[3],) if len(v) > 3 else (alpha,))
    v = [float(x) for x in re.findall(r"[\d.]+", c)]
    return (int(v[0]), int(v[1]), int(v[2]), int(round(v[3] * 255)) if len(v) > 3 else alpha)


def rm(c):
    return ",".join(str(x) for x in c)


def light(c):
    """The light theme's version of a colour (settings: DarkTheme = 0): its lightness flipped (HSL: L -> 1 - L; hue,
    saturation and alpha stay). lc-live.js flips the design's colours the same way (&theme=light)."""
    h, l, s_ = colorsys.rgb_to_hls(c[0] / 255, c[1] / 255, c[2] / 255)
    return tuple(round(v * 255) for v in colorsys.hls_to_rgb(h, 1 - l, s_)) + (c[3],)


def light_d(d):
    """A meter's data-* colours for the light theme (for the images the builder draws itself)."""
    hx = lambda c: "#" + "".join(f"{v:02x}" for v in light(rgba(c)))
    return {k: (hx(v) if k in ("on", "off", "gradient", "color", "fillColor", "warnColor", "fill", "stroke") and v else v)
            for k, v in d.items()}


def safe(key):
    return re.sub(r"[^A-Za-z0-9]", "_", key)


def write_png(path, w, h, px):
    """px: bytearray of RGBA rows."""
    raw = b"".join(b"\0" + bytes(px[y * w * 4:(y + 1) * w * 4]) for y in range(h))
    chunk = lambda t, d: struct.pack(">I", len(d)) + t + d + struct.pack(">I", zlib.crc32(t + d) & 0xFFFFFFFF)
    with open(path, "wb") as f:
        f.write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
                + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(4))


def arc_image(path, size, d):
    """Lit arc at 100 %, with the colour running from data-on to data-gradient along the sweep."""
    t = float(d.get("thickness", size * 0.1)); R = (size - t) / 2; c = size / 2
    start = float(d.get("start", 0)); sweep = float(d.get("sweep", 360))
    on = rgba(d.get("on", "#fff")); grad = rgba(d.get("gradient", d.get("on", "#fff")))
    rnd = "round" in d and d.get("round") not in ("false", "0")
    sx, sy = c + R * math.sin(math.radians(start)), c - R * math.cos(math.radians(start))
    ex, ey = c + R * math.sin(math.radians(start + sweep)), c - R * math.cos(math.radians(start + sweep))
    px = bytearray(size * size * 4)
    for y in range(size):
        for x in range(size):
            fx, fy = x + 0.5 - c, y + 0.5 - c
            r = math.hypot(fx, fy)
            th = (math.degrees(math.atan2(fx, -fy)) - start) % 360        # clockwise from the start
            if th <= sweep:
                dist, u = abs(r - R), th / sweep
            elif rnd:
                d0 = math.hypot(x + 0.5 - sx, y + 0.5 - sy); d1 = math.hypot(x + 0.5 - ex, y + 0.5 - ey)
                dist, u = (d0, 0.0) if d0 < d1 else (d1, 1.0)
            else:
                continue
            cov = max(0.0, min(1.0, t / 2 - dist + 0.5))
            if cov <= 0:
                continue
            col = lerp(on, grad, u)
            i = (y * size + x) * 4
            px[i:i + 4] = bytes((col[0], col[1], col[2], int(col[3] * cov)))
    write_png(path, size, size, px)


def bar_image(path, w, h, d):
    """Fully lit bar (segments and gradient); the Bar meter reveals it up to the value."""
    on = rgba(d.get("on", "#fff")); grad = rgba(d.get("gradient", d.get("on", "#fff")))
    n = int(float(d.get("segments", 0) or 0)); gap = float(d.get("gap", 0) or 0)
    fill = d.get("fill") or ("btt" if h > w else "ltr")
    vertical = fill in ("btt", "ttb"); L = h if vertical else w
    blk = (L - (n - 1) * gap) / n if n > 1 else L
    px = bytearray(w * h * 4)
    for y in range(h):
        for x in range(w):
            a = {"ltr": x, "rtl": w - 1 - x, "ttb": y, "btt": h - 1 - y}[fill] + 0.5
            if n > 1 and (a % (blk + gap)) > blk:
                continue
            col = lerp(on, grad, a / L)
            i = (y * w + x) * 4
            px[i:i + 4] = bytes(col)
    write_png(path, w, h, px)


def chrome(args):
    prof = os.path.join(os.environ.get("TEMP", HERE), "resmon-skin-build")
    return subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--user-data-dir={prof}",
                           "--force-device-scale-factor=1", "--allow-file-access-from-files",
                           "--virtual-time-budget=2500"] + args, capture_output=True, text=True, encoding="utf-8")


# ---------------------------------------------------------------- build
def copy_res(fname, out):
    """Copies a helper into the skin's res folder. Lua scripts are saved as UTF-16: only then does Rainmeter treat
    their strings as Unicode (icon glyphs, song titles with accents); otherwise it reads them as ANSI."""
    src, dst = os.path.join(HERE, fname), os.path.join(out, "res", fname)
    if fname.endswith(".lua"):
        with open(src, encoding="utf-8") as fh:
            text = fh.read()
        with open(dst, "w", encoding="utf-16", newline="\n") as fh:
            fh.write(text)
    else:
        shutil.copy(src, dst)


CSC = r"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"


def compile_npwatch(out):
    """Compiles npwatch.cs (the music auto-switch's watcher) with the C# compiler that ships with Windows.
    Returns False when that isn't possible, and the music auto-switch is left out."""
    exe = os.path.join(out, "res", "npwatch.exe")
    if os.path.exists(exe):
        return True
    fw, md = os.path.dirname(CSC), os.path.join(os.environ.get("WINDIR", r"C:\Windows"), "System32", "WinMetadata")
    refs = [os.path.join(md, "Windows.Media.winmd"), os.path.join(md, "Windows.Foundation.winmd"),
            os.path.join(md, "Windows.Storage.winmd"), os.path.join(fw, "System.Runtime.dll"),
            os.path.join(fw, "System.Drawing.dll")]
    if not all(os.path.exists(f) for f in [CSC] + refs):
        print("music auto-switch skipped: the .NET Framework C# compiler or Windows' media metadata is missing")
        return False
    r = subprocess.run([CSC, "/nologo", "/optimize", "/target:winexe", f"/out:{exe}"] + [f"/r:{f}" for f in refs]
                       + [os.path.join(HERE, "npwatch.cs")], capture_output=True, text=True)
    if r.returncode:
        print("music auto-switch skipped: npwatch.cs didn't compile:", r.stdout)
        return False
    return True


def page_name(design):
    return re.sub(r"[^A-Za-z0-9]+", " ", os.path.splitext(os.path.basename(design))[0]).title().replace(" ", "")


def icon_sprite(path, s):
    """Renders every weather icon at s x s px into one transparent horizontal strip (frame i = WX_ORDER[i])."""
    tmp = os.path.join(os.path.dirname(path), "_sprite.html")
    js = "file:///" + os.path.join(ROOT, "wx-icons.js").replace("\\", "/")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(f"""<!DOCTYPE html><html><head><style>html,body{{margin:0;background:transparent}}
div{{position:absolute;top:0;width:{s}px;height:{s}px}} svg{{width:100%;height:100%}}</style></head><body>
<script src="{js}"></script><script>
{json.dumps(WX_ORDER)}.forEach((k, i) => {{ const d = document.createElement('div'); d.style.left = (i * {s}) + 'px';
  d.innerHTML = WX_ICONS[k]; document.body.appendChild(d); }});</script></body></html>""")
    chrome([f"--window-size={s * len(WX_ORDER)},{max(s, 100)}", "--default-background-color=00000000",
            f"--screenshot={path}", "file:///" + tmp.replace("\\", "/")])
    os.remove(tmp)


WX_FRAMES, WX_FPS = 16, 8                 # animated icons: frames per loop, frames per second (a 2 s loop)
IDLE_FRAMES, IDLE_BOX = 24, (570, 40, 300, 200)   # idle banner controller: 3 s loop at WX_FPS; its area of the art


# settings.inc: the settings page's choices, as Rainmeter variables every page includes. The settings page
# (screens/settings.html, settings.lua) writes it with !WriteKeyValue, which Rainmeter allows only inside its
# Skins folder (replaced on every install) or its settings folder, so it lives in the settings folder:
# %APPDATA%\Rainmeter\ResMon\settings.inc. Rebuilding keeps it.
SETTINGS = os.path.join(os.environ.get("APPDATA", ROOT), "Rainmeter", "ResMon", "settings.inc")
BACKDROP = "ResMon\\Backdrop"             # the config that draws the page background under the pages
IGNOREFILE = "ignored-apps.txt"            # apps never treated as games (one exe per line)


def settings_file():
    """settings.inc as the builder writes it (a package build: the package's starting settings)."""
    return data_src("settings.inc") if PACKAGE else SETTINGS


def settings_rt():
    """settings.inc as the skin includes and writes it."""
    return rt("settings.inc") if PACKAGE else SETTINGS


def include_settings():
    """The [Variables] lines that read settings.inc. A package also reads its starting settings first, so a page
    works even before the starter skin has copied them."""
    pre = "@IncludeDefaults=#SKINSPATH#ResMon\\@Resources\\defaults\\settings.inc\n" if PACKAGE else ""
    return f"{pre}@Include={settings_rt()}"


def ensure_ignored():
    """ignored-apps.txt: made from autoswitch.json's old "ignore" list, which is then taken out of autoswitch.json."""
    ap = data_src("autoswitch.json")
    ign = data_src(IGNOREFILE)
    try:
        with open(ap, encoding="utf-8") as fh:
            text = fh.read()
        old = json.loads(text).get("ignore")
    except (OSError, ValueError):
        text, old = None, None
    if not os.path.exists(ign):
        with open(ign, "w", encoding="utf-8", newline="\n") as fh:
            fh.write("# Apps the Hyte screen never treats as games, even fullscreen and busy (one exe per line).\n"
                     "# Add one if it sends the screen to the gaming page. Changes apply when a page opens.\n"
                     + "".join(f"{n}\n" for n in (old or [])))
    if old is not None and text is not None:
        with open(ap, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(re.sub(r',\s*"ignore"\s*:\s*\[[^\]]*\]', "", text))
SETTING_DEFAULTS = [
    ("DarkTheme", "1", "dark theme (1) or light theme (0): light panels and dark text"),
    ("Transparency", "1", "see-through page background and panels (1 on, 0 off)"),
    ("BgOpacity", "25", "page background, % solid while see-through is on"),
    ("PanelOpacity", "80", "panels, % solid while see-through is on"),
    ("AnimWeather", "1", "animated weather icons"),
    ("AnimGaming", "1", "animated controller on the gaming page's idle banner"),
    ("AnimMusic", "1", "music page spectrum"),
    ("TempF", "0", "weather temperatures in Fahrenheit (1) or Celsius (0)"),
    ("SysTempF", "-1", "CPU and GPU temperatures in Fahrenheit (1) or Celsius (0); -1 follows TempF"),
    ("WindMph", "0", "weather page wind speed in mph (1) or km/h (0)"),
    ("Clock12", "0", "12-hour clock (1) or 24-hour (0); the 12-hour clock has no AM/PM, like a phone's lock screen"),
    ("AltCity", "Buenos Aires", "the city tapping the clock shows (one of CITIES in build_skin.py)"),
    ("WxCity", "", "weather location (one of weather.json's locations) and its coordinates"),
    ("WxCityLat", "", ""),
    ("WxCityLon", "", ""),
    ("GpuLoad", "50", "game detection: a fullscreen app counts as a game while the GPU is at least this % busy"),
    ("SettingsReturn", "Home", "the page the settings page's Done button goes back to"),
]


# cities for the second clock (tap the clock; settings: AltCity), with their Windows time zone ids
CITIES = [
    ("Buenos Aires", "Argentina Standard Time"), ("São Paulo", "E. South America Standard Time"),
    ("Santiago", "Pacific SA Standard Time"), ("Mexico City", "Central Standard Time (Mexico)"),
    ("New York", "Eastern Standard Time"), ("Chicago", "Central Standard Time"),
    ("Los Angeles", "Pacific Standard Time"), ("Honolulu", "Hawaiian Standard Time"),
    ("London", "GMT Standard Time"), ("Madrid", "Romance Standard Time"), ("Berlin", "W. Europe Standard Time"),
    ("Dubai", "Arabian Standard Time"), ("Mumbai", "India Standard Time"), ("Singapore", "Singapore Standard Time"),
    ("Tokyo", "Tokyo Standard Time"), ("Sydney", "AUS Eastern Standard Time"), ("Auckland", "New Zealand Standard Time"),
]
_TZ = None
# CPU/GPU temperatures in °F (1) or °C (0): SysTempF, or TempF while SysTempF is -1 (settings from before it existed)
SYS_TEMP_F = ("[mSysTempF]\nMeasure=Calc\nFormula=#SysTempF# < 0 ? #TempF# : #SysTempF#\nUpdateDivider=-1\n"
              "RegExpSubstitute=1\nSubstitute=\"^1$\":\"°F\",\"^0$\":\"°C\"\n")
CHOICES = {"AltCity": [c for c, _ in CITIES],   # settings with named choices (the settings page's < > buttons)
           # temperatures (settings.lua turns the choice into TempF and SysTempF)
           "TempUnits": ["Celsius", "°F weather", "Fahrenheit"]}
COORDS = {}                                     # setting -> {choice: (lat, lon)}: also sets <setting>Lat / <setting>Lon


def wx_places():
    """weather.json: the home location (name, latitude, longitude) and "locations" for the settings page."""
    try:
        with open(data_src("weather.json"), encoding="utf-8") as fh:
            w = json.load(fh)
    except (OSError, ValueError):
        return ("", 0, 0), []
    home = (w.get("name", ""), w.get("latitude", 0), w.get("longitude", 0))
    places = [(p["name"], p["latitude"], p["longitude"]) for p in w.get("locations", []) if p.get("name")]
    if home[0] and home[0] not in [p[0] for p in places]:
        places.insert(0, home)
    return home, places


def init_data():
    """Reads the weather places (call once DATA is set, before building)."""
    global SETTING_DEFAULTS
    # a fresh copy of the project has no weather.json of its own (it's yours, so it isn't shared): start from the example
    ex = os.path.join(ROOT, "weather.example.json")
    if not os.path.exists(data_src("weather.json")) and os.path.exists(ex):
        shutil.copy(ex, data_src("weather.json"))
    home, places = wx_places()
    # "Automatic": where this PC is (Windows' location service; see weather.ps1)
    CHOICES["WxCity"] = ["Automatic"] + [p[0] for p in places]
    COORDS["WxCity"] = {"Automatic": ("auto", "auto"), **{p[0]: (p[1], p[2]) for p in places}}
    # the weather location starts as weather.json's own (name, latitude, longitude); a package's, and one without
    # its own, start as Automatic (weather.json's place is then only the fallback when Windows can't say where it is)
    first = {"WxCity": home[0], "WxCityLat": str(home[1]), "WxCityLon": str(home[2])} if home[0] and not PACKAGE else \
        {"WxCity": "Automatic", "WxCityLat": "auto", "WxCityLon": "auto"}
    SETTING_DEFAULTS = [(k, first.get(k, v), n) for k, v, n in SETTING_DEFAULTS]


def tz_table():
    """{city: [[unix seconds, UTC offset hours], ...]}: each city's offset now and at every change over the next
    3 years, from Windows' time zone data (tzdump.ps1). Rebuilding the skin extends it."""
    global _TZ
    if _TZ is None:
        zones = ";".join(f"{c}={z}" for c, z in CITIES)
        r = subprocess.run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
                            os.path.join(HERE, "tzdump.ps1"), "-Zones", zones], capture_output=True, text=True,
                           encoding="utf-8")
        try:
            _TZ = json.loads(r.stdout)
        except ValueError:
            print("warning: couldn't read the time zones (second clock uses its HTML offset):", r.stderr.strip())
            _TZ = {}
    return _TZ


def ensure_settings():
    """Creates settings.inc with the defaults, or adds settings a newer version introduced (keeps your values).
    An older look.json's opacities become the starting values."""
    have = {}
    if PACKAGE:
        lines = ["; ResMon settings: changed by the screen's settings page (the gear next to the page dots).",
                 "; Rainmeter variables, read by every page when it opens (you can also edit them here).",
                 "[Variables]"]
        for k, v, note in SETTING_DEFAULTS:
            lines += [f"; {note}"] if note else []
            lines.append(f"{k}={v}")
        with open(settings_file(), "w", encoding="utf-16", newline="\r\n") as fh:
            fh.write("\n".join(lines) + "\n")
        return
    os.makedirs(os.path.dirname(SETTINGS), exist_ok=True)
    old = os.path.join(ROOT, "settings.inc")          # where an earlier version kept it
    if os.path.exists(old) and not os.path.exists(SETTINGS):
        shutil.move(old, SETTINGS)
    if os.path.exists(SETTINGS):
        with open(SETTINGS, encoding="utf-16") as fh:
            for line in fh:
                m = re.match(r"\s*([A-Za-z_]\w*)\s*=(.*)$", line)
                if m:
                    have[m.group(1)] = m.group(2).strip()
    ap = os.path.join(ROOT, "autoswitch.json")      # an older autoswitch.json's gpu_load (moved here)
    try:
        with open(ap, encoding="utf-8") as fh:
            atext = fh.read()
        gl = json.loads(atext).get("gpu_load")
    except (OSError, ValueError):
        atext, gl = None, None
    if gl is not None and "GpuLoad" not in have:
        have["GpuLoad"] = str(gl)
    lp = os.path.join(ROOT, "look.json")
    if os.path.exists(lp):
        with open(lp, encoding="utf-8") as fh:
            look = json.load(fh)
        for key, var in (("background_opacity", "BgOpacity"), ("panel_opacity", "PanelOpacity")):
            if key in look and var not in have:
                have[var] = str(round(float(look[key]) * 100))
        os.remove(lp)
    lines = ["; ResMon settings: changed by the screen's settings page (the gear next to the page dots).",
             "; Rainmeter variables, read by every page when it opens (you can also edit them here).",
             "[Variables]"]
    for k, v, note in SETTING_DEFAULTS:
        lines.append(f"; {note}")
        lines.append(f"{k}={have.get(k, v)}")
    # Rainmeter's !WriteKeyValue keeps UTF-16 files as UTF-16
    with open(SETTINGS, "w", encoding="utf-16", newline="\r\n") as fh:
        fh.write("\n".join(lines) + "\n")
    if gl is not None and atext is not None:
        with open(ap, "w", encoding="utf-8", newline="\n") as fh:
            fh.write(re.sub(r'\n\s*"gpu_load"\s*:\s*[\d.]+,', "", atext))


def wx_anim():
    """weather.json "animate_icons" (default true): animate the weather icons."""
    try:
        with open(data_src("weather.json"), encoding="utf-8") as fh:
            return bool(json.load(fh).get("animate_icons", True))
    except (OSError, ValueError):
        return True


def icon_frames(res, s, frames):
    """Animated icons: for each weather icon (index i = WX_ORDER[i]) a transparent strip wx_<s>_<i>.png of
    `frames` frames at s x s px, one loop of wx-icons.js's WX_ICON_FRAME. One strip per icon keeps each image
    small: a slot only loads the icon it shows."""
    tmp = os.path.join(res, "_frames.html")
    js = "file:///" + os.path.join(ROOT, "wx-icons.js").replace("\\", "/")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(f"""<!DOCTYPE html><html><head><style>html,body{{margin:0;background:transparent}}
div{{position:absolute;top:0;width:{s}px;height:{s}px}} svg{{width:100%;height:100%}}</style></head><body>
<script src="{js}"></script><script>
const k = WX_ORDER[+new URLSearchParams(location.search).get('i')];
for (let f = 0; f < {frames}; f++) {{ const d = document.createElement('div'); d.style.left = (f * {s}) + 'px';
  d.innerHTML = WX_ICON_FRAME(k, f / {frames}); document.body.appendChild(d); }}</script></body></html>""")
    for i in range(len(WX_ORDER)):
        chrome([f"--window-size={s * frames},{max(s, 100)}", "--default-background-color=00000000",
                f"--screenshot={os.path.join(res, f'wx_{s}_{i}.png')}", "file:///" + tmp.replace("\\", "/") + f"?i={i}"])
    os.remove(tmp)


def build(design, size=None, out=None, pages=None, index=0, gear=False):
    """gear: draw the settings gear next to the page dots (there's a settings page)."""
    design = os.path.abspath(design)
    name = page_name(design)
    pages = pages or [name]
    out = out or os.path.join(HERE, "ResMon", "Screen")
    res = os.path.join(out, "res", name)
    os.makedirs(res, exist_ok=True)
    url = "file:///" + design.replace("\\", "/") + "?mode=geom"

    # the page is laid out at an explicit scale (&scale=), not fitted to headless Chrome's viewport
    geo = lambda: json.loads(re.search(r'<script type="application/json" id="lc-geom">(.*?)</script>',
                                       chrome(["--window-size=1200,4400", "--dump-dom", url]).stdout, re.S).group(1))
    g = geo()
    W, H = int(g["width"]), int(g["height"])
    # Rainmeter is DPI-unaware: on a 150 % display it works in logical pixels and Windows stretches the skin.
    # --size gives the display's size in those logical pixels; the design is scaled down to fit it.
    tw, th = size or (W, H)
    # a screen taller in proportion than the design (the Y70 Touch Infinite: 682x2560 against 1100x3840): the page is
    # made taller to match and lc-live.js spreads the panels over the extra height (&tall=, in design px)
    if th / tw > H / W * 1.005:
        url += f"&tall={round(th * W / tw)}"
        g = geo()
        W, H = int(g["width"]), int(g["height"])
    k = scale = min(tw / W, th / H)
    # the static art in three transparent layers: the page background, the panels' fill, and everything else
    # (background.png). The skin fades the first two by the see-through settings (settings.inc), live.
    # The page background is drawn by the backdrop skin (ResMon\Backdrop, which stays loaded while pages change, so a
    # swipe doesn't flash the wallpaper) one pixel larger than the page: the display's size in Rainmeter's pixels
    # isn't whole (1100 / 1.5 = 733.3), and the last fraction of a pixel would show the wallpaper.
    # Each layer is drawn twice: dark, and light (&theme=light, files ending in _l; settings: DarkTheme).
    for layer, fn in (("bg", "fill_bg"), ("panels", "fill_panels"), ("art", "background")):
        grow = 1 if layer == "bg" else 0
        for thq, sfx in (("", ""), ("&theme=light", "_l")):
            chrome([f"--window-size={tw + grow},{th + grow}", "--default-background-color=00000000",
                    f"--screenshot={os.path.join(res, fn + sfx + '.png')}", f"{url}&scale={k}&layer={layer}{thq}"])
    # data-group: each group's static art as its own transparent image, so the skin can hide the whole group
    groups = []
    for gr in g.get("groups", []):
        gx, gy = round(gr["x"] * k), round(gr["y"] * k)
        gw, gh = round(gr["w"] * k), round(gr["h"] * k)
        for thq, sfx in (("", ""), ("&theme=light", "_l")):
            chrome([f"--window-size={gw},{gh}", "--default-background-color=00000000",
                    f"--screenshot={os.path.join(res, 'group_' + gr['name'] + sfx + '.png')}",
                    f"{url}&scale={k}&only={gr['name']}&ox={gr['x']}&oy={gr['y']}{thq}"])
        groups.append(dict(gr, x=gx, y=gy, w=gw, h=gh))
    for r in g["runs"]:
        for a in ("x", "y", "w", "h", "size", "clipW", "lineH"):
            if r.get(a) is not None:
                r[a] *= k
    for mt in g["meters"]:
        for a in ("x", "y", "w", "h"):
            mt[a] *= k
        for a in ("thickness", "gap", "block", "lineWidth", "radius", "knob", "lineWidthm"):
            if mt["d"].get(a) not in (None, ""):
                mt["d"][a] = str(float(mt["d"][a]) * k)
    W, H = tw, th

    meters, measures, variables = [], [], {}
    keys = set()                          # sensor keys whose value is needed
    weather = set()                       # WX_* keys (variables set by wx.lua)
    wx_num = set()                        # WX_* keys used in formulas (default 0, not "--")
    game = {}                             # GAME_* keys (variables set by game.lua from gameinfo.ps1) -> image size
    np_ = {}                              # NP_* keys (now playing; variables set by np.lua) -> image size
    buttons = []                          # touch buttons, drawn last so they sit on top of everything
    tz_area, tz, tz_day = [], None, []    # data-action="timezone": tap the clock to see another time zone
    anim_icons = []                       # animated weather icon slots (weather.json "animate_icons")
    img_pos = {}                          # data-lc="image" key -> (x, y, w, h) in skin px
    idle_anim = False                     # the gaming page's idle banner has an animated controller
    visual = []                           # AudioLevel measures for data-lc="visualizer"
    warn = {}                             # (key, threshold) -> [(true action, false action)]
    settings_ui = {}                      # settings page controls: "toggles" (switches), "vars" (+/- values)

    # the theme (settings: DarkTheme, 1 dark / 0 light). A colour that differs between them becomes a pair of variables
    # tc_<n>1 (dark) / tc_<n>0 (light) read as [#tc_<n>[#DarkTheme]]; a picture drawn for both themes is
    # <name>.png / <name>_l.png, read as <name>[#thPng[#DarkTheme]]. A theme change reloads the pages.
    themed = {}
    variables["thPng1"], variables["thPng0"] = ".png", "_l.png"

    def tc(c):
        dk, lt = rm(c), rm(light(c))
        if dk == lt:
            return dk
        if dk not in themed:
            themed[dk] = f"tc_{len(themed)}"
            variables[themed[dk] + "1"], variables[themed[dk] + "0"] = dk, lt
        return f"[#{themed[dk]}[#DarkTheme]]"

    def ti(base):
        return f"#@#{base}[#thPng[#DarkTheme]]"

    def need(key):
        keys.add(key)
        return "v_" + safe(key)

    def add_warn(key, d, on_true, on_false):
        if d.get("warn") not in (None, ""):
            warn.setdefault((key, float(d["warn"])), []).append((on_true, on_false))

    # ---- arcs, bars, charts
    for i, mt in enumerate(g["meters"]):
        d, kind = mt["d"], mt["kind"]
        x, y, w, h = round(mt["x"]), round(mt["y"]), round(mt["w"]), round(mt["h"])
        if kind == "arc":
            h = w
        if kind == "button" and d.get("action") == "timezone":
            # tap the clock: every clock/date on the page shows another time zone for a few seconds.
            # The press also starts a swipe (this area covers the skin's own swipe handler), and the release
            # counts as a tap only if the finger didn't travel (see mTzTap below).
            tz = dict(offset=d.get("tz", "0"), name=d.get("tzName", ""), seconds=int(d.get("seconds", 5)))
            tz_area.append(f"""[tzArea{i}]
Meter=Image
SolidColor=0,0,0,1
X={x}
Y={y}
W={w}
H={h}
LeftMouseDownAction=[!SetVariable SwipeX0 "$MouseX$"][!SetVariable SwipeX1 "$MouseX$"][!SetVariable SwipeOn 1][!UpdateMeasure mSwipeAge]
LeftMouseUpAction=[!SetVariable SwipeX1 "$MouseX$"][!UpdateMeasure mSwipe][!UpdateMeasure mTzTap][!SetVariable SwipeOn 0]
""")
            continue
        if kind == "button" and d.get("action") == "open":
            # settings page: open a list in Notepad (known-games.txt, ignored-apps.txt) or the ResMon folder
            t = d.get("target", "")
            run = ({"known": f'["notepad.exe" "{rt('known-games.txt')}"]',
                    "ignored": f'["notepad.exe" "{rt(IGNOREFILE)}"]'}.get(t) or f'["explorer.exe" "{data_dir_rt()}"]')
            buttons.append(f"[btn{i}]\nMeter=Image\nSolidColor=0,0,0,1\nX={x}\nY={y}\nW={w}\nH={h}\n"
                           f"LeftMouseUpAction={run}\n")
            continue
        if kind == "button" and d.get("action") in ("setting", "cycle", "done"):
            # settings page: data-var with data-step (+/- within data-min..data-max), data-action="cycle" with
            # data-dir (next/previous of the setting's choices, e.g. AltCity's cities), or Done (back to the page
            # the gear was tapped on); settings.lua does the work
            if d["action"] == "cycle":
                call = f"Cycle('{d.get('var', '')}', {int(d.get('dir', 1))})"
                settings_ui.setdefault("cycles", set()).add(d.get("var", ""))
            else:
                call = ("Done()" if d["action"] == "done" else
                        f"Step('{d.get('var', '')}', {float(d.get('step', 1)):g}, {float(d.get('min', 0)):g}, {float(d.get('max', 100)):g})")
            settings_ui.setdefault("vars", set()).add(d.get("var", "")) if d["action"] == "setting" else None
            buttons.append(f"[btn{i}]\nMeter=Image\nSolidColor=0,0,0,1\nX={x}\nY={y}\nW={w}\nH={h}\n"
                           f"LeftMouseUpAction=[!CommandMeasure mSettings \"{call}\"]\n")
            continue
        if kind == "toggle":
            # settings page: an on/off switch for data-var; settings.lua sets its colour (tgFill_<var>)
            var = d.get("var", "")
            settings_ui.setdefault("toggles", []).append(var)
            variables[f"tgFill_{var}"] = "58,74,98,255"
            r_ = h / 2; kr = r_ - max(2, 7 * scale)
            buttons.append(f"""[tg{i}]
Meter=Shape
X={x}
Y={y}
Shape=Rectangle 0,0,{w},{h},{r_:.1f} | Fill Color #tgFill_{var}# | StrokeWidth 0
Shape2=Ellipse (#{var}# = 1 ? {w - r_:.1f} : {r_:.1f}),{r_:.1f},{kr:.1f} | Fill Color 244,248,255,255 | StrokeWidth 0
DynamicVariables=1
LeftMouseUpAction=[!CommandMeasure mSettings "Toggle('{var}')"]
""")
            continue
        if kind == "button":
            # invisible touch area; a tap runs np.lua's Press(<action>) (and never counts as a swipe)
            buttons.append(f"""[btn{i}]
Meter=Image
SolidColor=0,0,0,1
X={x}
Y={y}
W={w}
H={h}
LeftMouseUpAction=[!SetVariable SwipeOn 0][!CommandMeasure mNP "Press('{d.get('action', '')}')"]
""")
            continue
        if kind == "visualizer":
            # spectrum bars driven by Rainmeter's AudioLevel plugin (what the speakers play), with a faint mirror
            n = int(d.get("bars", 40)); gap = float(d.get("gap", 6 * scale)); rf = float(d.get("reflect", 0.2))  # gap: scaled above
            bw = (w - (n - 1) * gap) / n
            BW, BH = max(1, round(bw)), round(h / (1 + rf))
            off_ = max(1, round(4 * scale)); RH = max(1, h - BH - off_)
            for dd, sfx in ((d, ""), (light_d(d), "_l")):
                on = rgba(dd.get("on", "#3DE0FF")); grad = rgba(dd.get("gradient", dd.get("on", "#3DE0FF")))
                if sfx:
                    on, grad = (on, grad) if "on" in d else (light(on), light(grad))
                px = bytearray(BW * BH * 4)
                for yy in range(BH):
                    col = bytes(lerp(on, grad, (BH - 1 - yy) / max(1, BH - 1)))
                    for xx in range(BW):
                        px[(yy * BW + xx) * 4:(yy * BW + xx) * 4 + 4] = col
                write_png(os.path.join(res, f"vis{i}{sfx}.png"), BW, BH, px)
                px = bytearray(BW * RH * 4)
                for yy in range(RH):
                    col = bytes(on[:3] + (int(on[3] * 0.25 * (1 - yy / RH) ** 1.5),))
                    for xx in range(BW):
                        px[(yy * BW + xx) * 4:(yy * BW + xx) * 4 + 4] = col
                write_png(os.path.join(res, f"visr{i}{sfx}.png"), BW, RH, px)
            visual.append(f"""[mAudio{i}]
Measure=Plugin
Plugin=AudioLevel
Port=Output
FFTSize=4096
FFTOverlap=2048
FFTAttack=15
FFTDecay=220
Bands={n}
FreqMin={d.get("fmin", 60)}
FreqMax={d.get("fmax", 12000)}
Sensitivity={d.get("sensitivity", 50)}
UpdateDivider=1
""")
            for j in range(n):
                visual.append(f"[mBand{i}_{j}]\nMeasure=Plugin\nPlugin=AudioLevel\nParent=mAudio{i}\nType=Band\nBandIdx={j}\nUpdateDivider=1\n")
                bx = round(x + j * (bw + gap))
                for nm_, yy, hh, img, flip in ((f"vis{i}_{j}", y, BH, f"vis{i}", 0), (f"visr{i}_{j}", y + BH + off_, RH, f"visr{i}", 1)):
                    meters.append(f"[{nm_}]\nMeter=Bar\nMeasureName=mBand{i}_{j}\nBarImage={ti(img)}\nBarOrientation=Vertical\n"
                                  f"Flip={flip}\nX={bx}\nY={yy}\nW={BW}\nH={hh}\nUpdateDivider=1\n")
            continue
        key = (d.get("sensor") or "").upper() if not (d.get("sensor") or "").startswith("HW:") else d["sensor"]
        if not key:
            continue
        if kind == "marker":
            # a dot that slides along a scale: data-range px to the right at data-max (the element sits at 0)
            mx = float(d.get("max", 100)); rng = float(d.get("range", 0)) * scale
            if key.startswith("WX_"):
                weather.add(key); wx_num.add(key)
            fill = tc(rgba(d.get("fill", "#fff"))); stroke = tc(rgba(d.get("stroke", "#000")))
            sw = float(d.get("strokeWidth", 0)) * scale; rr = w / 2
            meters.append(f"""[mk{i}]
Meter=Shape
X=({x}+Clamp(#{key}#/{mx},0,1)*{rng:.1f})
Y={y}
Shape=Ellipse {rr:.1f},{rr:.1f},{rr - sw / 2:.1f} | Fill Color {fill} | StrokeWidth {sw:.1f} | StrokeColor {stroke}
DynamicVariables=1
""")
            continue
        if kind == "icon":
            sz = w
            weather.add(key)
            src_t = os.path.getmtime(os.path.join(ROOT, "wx-icons.js"))
            fresh = lambda f: os.path.exists(f) and os.path.getmtime(f) >= src_t   # redraw after wx-icons.js changes
            if wx_anim():
                # animated: the slot shows frame [mWxFrame] of its icon's strip (see icon_frames)
                if not fresh(os.path.join(res, f"wx_{sz}_{len(WX_ORDER) - 1}.png")):
                    icon_frames(res, sz, WX_FRAMES)
                anim_icons.append(i)
                meters.append(f"""[icon{i}]
Meter=Image
ImageName=#@#wx_{sz}_#{key}#.png
ImageCrop=([mWxFrame]*{sz}),0,{sz},{sz}
X={x}
Y={y}
W={sz}
H={sz}
DynamicVariables=1
UpdateDivider=1
""")
                continue
            sprite = f"wx_{sz}.png"
            if not fresh(os.path.join(res, sprite)):
                icon_sprite(os.path.join(res, sprite), sz)
            meters.append(f"""[icon{i}]
Meter=Image
ImageName=#@#{sprite}
ImageCrop=(#{key}#*{sz}),0,{sz},{sz}
X={x}
Y={y}
W={sz}
H={sz}
DynamicVariables=1
""")
            continue
        if kind == "image":
            # live picture (GAME_HERO / GAME_LOGO / NP_ART): the helper script renders it at exactly this size
            (game if key.startswith("GAME_") else np_)[key] = f"{w}x{h}"
            img_pos[key] = (x, y, w, h)
            meters.append(f"""[img{i}]
Meter=Image
ImageName=#{key}#
X={x}
Y={y}
W={w}
H={h}
DynamicVariables=1
""")
            continue
        v = need(key)
        mx = float(d["max"]) if d.get("max") not in (None, "", "auto") else MAX.get(key, 100)
        nm = f"{kind}{i}"
        if kind == "arc":
            t = float(d.get("thickness", w * 0.1)); R = (w - t) / 2; cx, cy = x + w / 2, y + w / 2
            start = float(d.get("start", 0)); sweep = float(d.get("sweep", 360))
            on = rgba(d.get("on", "#fff")); grad = rgba(d.get("gradient", d.get("on", "#fff")))
            off = rgba(d.get("off", "#000"))
            rnd = "round" in d and d.get("round") not in ("false", "0")
            cap = "Round" if rnd else "Flat"
            arc_image(os.path.join(res, f"{nm}.png"), w, d)
            arc_image(os.path.join(res, f"{nm}_l.png"), w, light_d(d))
            onL, gradL = light(on), light(grad)
            measures.append(f"""[c_{nm}_p]
Measure=Calc
Formula=Clamp({v}/{mx},0.002,1)
; a full arc has nothing left to cover (a zero-length cover leaves a hairline in the end cap)
IfCondition=c_{nm}_p >= 0.999
IfTrueAction=[!HideMeter {nm}_cover]
IfFalseAction=[!ShowMeter {nm}_cover]

[c_{nm}_x]
Measure=Calc
Formula={cx:.2f}+{R:.2f}*Sin(({start}+{sweep}*c_{nm}_p)*PI/180)

[c_{nm}_y]
Measure=Calc
Formula={cy:.2f}-{R:.2f}*Cos(({start}+{sweep}*c_{nm}_p)*PI/180)

[c_{nm}_big]
Measure=Calc
Formula=({sweep}*c_{nm}_p > 180) ? 1 : 0

[c_{nm}_rest]
Measure=Calc
Formula=({sweep}*(1-c_{nm}_p) > 180) ? 1 : 0
""" + "".join(f"""
[c_{nm}_{ch}]
Measure=Calc
Formula=#DarkTheme# = 1 ? Round({on[k]}+({grad[k] - on[k]})*c_{nm}_p) : Round({onL[k]}+({gradL[k] - onL[k]})*c_{nm}_p)
""" for k, ch in enumerate("rgb")))
            ex, ey = cx + R * math.sin(math.radians(start + sweep)), cy - R * math.cos(math.radians(start + sweep))
            sx, sy = cx + R * math.sin(math.radians(start)), cy - R * math.cos(math.radians(start))
            variables[f"vis_{nm}"] = "0"
            meters.append(f"""[{nm}_lit]
Meter=Image
ImageName={ti(nm)}
X={x}
Y={y}
W={w}
H={w}

[{nm}_cover]
Meter=Shape
X=0
Y=0
DynamicVariables=1
Shape=Path P | StrokeWidth {t + 2:.1f} | StrokeColor {tc(off)} | StrokeStartCap Flat | StrokeEndCap {cap} | Fill Color 0,0,0,0
P=[c_{nm}_x:3],[c_{nm}_y:3] | ArcTo {ex:.3f},{ey:.3f},{R:.3f},{R:.3f},0,0,[c_{nm}_rest]

[{nm}_dot]
Meter=Shape
X=0
Y=0
DynamicVariables=1
Hidden={0 if rnd else 1}
Shape=Ellipse [c_{nm}_x:3],[c_{nm}_y:3],{t / 2:.2f} | StrokeWidth 0 | Fill Color [c_{nm}_r],[c_{nm}_g],[c_{nm}_b],{on[3]}

[{nm}_warn]
Meter=Shape
X=0
Y=0
DynamicVariables=1
Hidden=1
Shape=Path P | StrokeWidth {t:.1f} | StrokeColor {tc(rgba(d.get('warnColor', '#FF4D4D')))} | StrokeStartCap {cap} | StrokeEndCap {cap} | Fill Color 0,0,0,0
P={sx:.3f},{sy:.3f} | ArcTo [c_{nm}_x:3],[c_{nm}_y:3],{R:.3f},{R:.3f},0,0,[c_{nm}_big]
""")
            add_warn(key, d, f"[!ShowMeter {nm}_warn][!HideMeter {nm}_dot]",
                     f"[!HideMeter {nm}_warn]" + (f"[!ShowMeter {nm}_dot]" if rnd else ""))
        elif kind in ("bar", "slider"):
            n = int(float(d.get("segments", 0) or 0))
            bar_image(os.path.join(res, f"{nm}.png"), w, h, d)
            bar_image(os.path.join(res, f"{nm}_l.png"), w, h, light_d(d))
            q = f"Round(Clamp({v}/{mx},0,1)*{n})/{n}" if n > 1 else f"Clamp({v}/{mx},0,1)"
            fill = d.get("fill") or ("btt" if h > w else "ltr")
            measures.append(f"""[c_{nm}]
Measure=Calc
Formula={q}
MinValue=0
MaxValue=1
""")
            meters.append(f"""[{nm}]
Meter=Bar
MeasureName=c_{nm}
BarImage={ti(nm)}
BarOrientation={'Vertical' if fill in ('btt', 'ttb') else 'Horizontal'}
Flip={1 if fill in ('rtl', 'ttb') else 0}
X={x}
Y={y}
W={w}
H={h}
""")
        elif kind == "chart":
            col = rgba(d.get("color", "#fff")); fc = rgba(d["fillColor"]) if d.get("fillColor") else None
            auto = d.get("max") == "auto"
            measures.append(f"""[c_{nm}]
Measure=Calc
Formula={v}
MinValue=0
MaxValue={mx}
""")
            lw = max(1, round(float(d.get("lineWidth", 2))))
            if fc:
                meters.append(f"""[{nm}_area]
Meter=Histogram
MeasureName=c_{nm}
PrimaryColor={tc(fc)}
AutoScale={1 if auto else 0}
AntiAlias=1
X={x}
Y={y}
W={w}
H={h - 1}
""")
            for k in range(lw):
                meters.append(f"""[{nm}_line{k}]
Meter=Line
MeasureName=c_{nm}
LineCount=1
LineColor={tc(col)}
AutoScale={1 if auto else 0}
AntiAlias=1
X={x}
Y={y - lw // 2 + k}
W={w}
H={h - 1}
""")

    # ---- text
    for i, r in enumerate(g["runs"]):
        nm = f"t{i}"
        col = rgba(r["color"])
        # its colour in each theme: col_<meter>1 (dark) / col_<meter>0 (light); a warning changes both
        variables[f"col_{nm}1"], variables[f"col_{nm}0"] = rm(col), rm(light(col))
        if r.get("colorVar"):                       # data-color-var: the colour comes from a variable (e.g. set by wx.lua)
            variables.setdefault(r["colorVar"], rm(col))
        size = r["size"]
        y = round(r["y"] + TEXT_DY * size / 100)
        align = {"left": "Left", "right": "Right", "center": "Center"}[r["anchor"]]
        x = {"Left": r["x"], "Right": r["x"] + r["w"], "Center": r["x"] + r["w"] / 2}[align]
        if r.get("chained"):
            prev = g["runs"][i - 1]
            xs = f"{round(r['x'] - (prev['x'] + prev['w']))}R"
        else:
            xs = str(round(x))
        src = ""
        clock = False
        if r["live"]:
            key = r["sensor"] if r["sensor"].startswith("HW:") else r["sensor"].upper()
            sub = r.get("sub") or ""
            if (key, sub) in TIMEFMT or (key, "") in TIMEFMT:
                fmt = TIMEFMT.get((key, sub)) or TIMEFMT[(key, "")]
                tm = f"tm_{safe(fmt)}"
                clock = fmt in TIME12
                if not any(s.startswith(f"[{tm}]") for s in measures) and fmt in TIME12:
                    # hours: the Clock12 setting picks the format (fmt_<measure>0 = 24-hour, fmt_<measure>1 = 12-hour)
                    fv = f"fmt_{tm}"
                    variables[fv + "0"], variables[fv + "1"] = fmt, TIME12[fmt]
                    measures.append(f"[{tm}]\nMeasure=Time\nFormat=[#{fv}[#Clock12]]\nFormatLocale=en-US\n"
                                    + (f"TimeZone=#ClockTZ#\nDaylightSavingTime=0\nGroup=Clock\n" if tz else "")
                                    + "DynamicVariables=1\n")
                elif not any(s.startswith(f"[{tm}]") for s in measures):
                    if tz:
                        # the zone (and, for the day name, the text) follow variables the clock tap changes
                        fv = f"fmt_{tm}"
                        variables[fv] = fmt
                        if key == "DAY":
                            tz_day.append((fv, fmt))
                        measures.append(f"[{tm}]\nMeasure=Time\nFormat=#{fv}#\nFormatLocale=en-US\nTimeZone=#ClockTZ#\n"
                                        f"DaylightSavingTime=0\nDynamicVariables=1\nGroup=Clock\n")
                    else:
                        measures.append(f"[{tm}]\nMeasure=Time\nFormat={fmt}\nFormatLocale=en-US\n")
                src = f"MeasureName={tm}\n"
            elif key == "WIND_UNIT":
                # the wind speed unit (settings: WindMph)
                variables["windUnit0"], variables["windUnit1"] = "km/h", "mph"
                src = "Text=[#windUnit[#WindMph]]\n"
            elif key == "WX_TEMP_UNIT":
                # the weather's temperature unit (settings: TempF)
                variables["tempUnit0"], variables["tempUnit1"] = "°C", "°F"
                src = "Text=[#tempUnit[#TempF]]\n"
            elif key == "TEMP_UNIT":
                # the CPU/GPU temperature unit (settings: SysTempF, or TempF while that's -1)
                if not any(m_.startswith("[mSysTempF]") for m_ in measures):
                    measures.append(SYS_TEMP_F)
                src = "MeasureName=mSysTempF\n"
            elif key.startswith("WX_"):
                weather.add(key)
                src = f"Text=#{key}#\n"
            elif key.startswith("GAME_"):
                game.setdefault(key, "")
                src = f"Text=#{key}#\n"
            elif key.startswith("NP_"):
                np_.setdefault(key, "")
                src = f"Text=#{key}#\n"
            elif key == "SET_TEMPUNITS":
                # the temperature choice: settings.lua sets it from TempF and SysTempF
                variables["TempUnits"] = CHOICES["TempUnits"][0]
                src = "Text=#TempUnits#\n"
            elif key.startswith("SET_"):
                # a setting's value (any page): the variable itself (settings.inc), e.g. SET_BgOpacity, SET_WxCity
                src = f"Text=#{r['sensor'][4:]}#\n"
            elif key in ("CPUMODEL", "GPUMODEL"):
                ref = "CPULOAD" if key == "CPUMODEL" else "GPUTEMP"
                keys.add(ref)
                measures.append(f"""[m_{key}]
Measure=Registry
RegHKey=HKEY_CURRENT_USER
RegKey=Software\\HWiNFO64\\VSB
RegValue=Sensor#idx_{safe(ref)}#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^[^:]*:\\s*([^:]+?)\\s*(:.*)?$":"\\1"
""")
                src = f"MeasureName=m_{key}\n"
            else:
                mv = need(key)
                if key.endswith("TEMP") or key == "GPUHOTSPOT":
                    # a temperature (HWiNFO gives °C): the text shows it in °F while mSysTempF is 1; warnings and
                    # arcs keep using the °C value
                    if not any(m_.startswith("[mSysTempF]") for m_ in measures):
                        measures.append(SYS_TEMP_F)
                    if not any(m_.startswith(f"[{mv}_t]") for m_ in measures):
                        measures.append(f"[{mv}_t]\nMeasure=Calc\nFormula=mSysTempF = 1 ? {mv} * 1.8 + 32 : {mv}\n")
                    mv += "_t"
                src = f"MeasureName={mv}\nNumOfDecimals={int(r.get('decimals') or DEC.get(key, 0))}\n"
                d = {"warn": r.get("warn"), "warnColor": r.get("warnColor")}
                wc = rgba(r.get("warnColor") or "#FF4D4D")
                add_warn(key, d, f'[!SetVariable col_{nm}1 "{rm(wc)}"][!SetVariable col_{nm}0 "{rm(light(wc))}"]',
                         f'[!SetVariable col_{nm}1 "{rm(col)}"][!SetVariable col_{nm}0 "{rm(light(col))}"]')
        else:
            src = f"Text={r['text']}\n"
        meters.append(f"""[{nm}]
Meter=String
{src}X={xs}
Y={y}
StringAlign={align}
FontFace={r['font']}
FontWeight={r['weight']}
FontSize={size * PT:.2f}
StringStyle={'Italic' if r['italic'] else 'Normal'}
FontColor={('#' + r['colorVar'] + '#') if r.get('colorVar') else f'[#col_{nm}[#DarkTheme]]'}
AntiAlias=1
DynamicVariables=1
""" + (f"W={round(r['clipW'])}\nH={round(r['lines'] * size * 1.3)}\nClipString=1\n" if r.get("lines") else ""))
        if clock:
            # 12-hour clock (settings: Clock12): a small grey AM/PM just after the time, on its baseline, following the
            # time's width; hidden while the clock is 24-hour.
            if not any(m_.startswith("[tm_apm]") for m_ in measures):
                measures.append("[tm_apm]\nMeasure=Time\nFormat=%p\nFormatLocale=en-US\n"
                                + ("TimeZone=#ClockTZ#\nDaylightSavingTime=0\nDynamicVariables=1\nGroup=Clock\n" if tz else ""))
            s2 = max(14, round(size * 0.2))
            # the time's right edge: from its anchor and its width now ([meter:W], a section variable)
            gap = max(3, round(size * 0.05))
            apm_x = {"Center": f"({round(x)}+[{nm}:W]/2+{gap})", "Right": f"({round(x)}+{gap})",
                     "Left": f"({round(x)}+[{nm}:W]+{gap})"}[align]
            meters.append(f"""[{nm}_apm]
Meter=String
MeasureName=tm_apm
X={apm_x}
Y={y + round((size - s2) * APM_DY)}
StringAlign=Left
FontFace={r['font']}
FontWeight=500
FontSize={s2 * PT:.2f}
FontColor={tc((143, 163, 191, 255) if size >= 100 else (107, 127, 156, 255))}
AntiAlias=1
Hidden=(1-#Clock12#)
DynamicVariables=1
""")

    # ---- auto-switch to the gaming page while a game is focused (settings: autoswitch.json)
    auto = None
    ap_ = data_src("autoswitch.json")
    if pages and len(pages) > 1 and os.path.exists(ap_):
        with open(ap_, encoding="utf-8") as fh:
            auto = json.load(fh)
        if not auto.get("enabled", True) or page_name(auto.get("page", "gaming.html")) not in pages:
            auto = None
    if auto:
        need("FPS"), need("GPULOAD")

    # ---- auto-switch to the music page while music plays (settings: autoswitch.json "music")
    music = None
    if pages and len(pages) > 1 and os.path.exists(ap_):
        with open(ap_, encoding="utf-8") as fh:
            music = json.load(fh).get("music")
        if (not music or not music.get("enabled", True) or page_name(music.get("page", "music.html")) not in pages
                or not compile_npwatch(out)):
            music = None
    # npwatch.exe reports the media status and which known game is running; game.lua and music.lua (re)start it
    watch = ""
    if (auto or music) and compile_npwatch(out):
        watch = ("Watcher=#CURRENTPATH#res\\npwatch.exe\nStatus=#CURRENTPATH#res\\npstatus.txt\n"
                 f"Known={rt('known-games.txt')}\nRunning=#CURRENTPATH#res\\running-game.txt\n"
                 f"History={rt('np-history')}\nFocus=#CURRENTPATH#res\\focus.txt\n")

    # ---- sensor measures
    raw = {}                                            # key -> HWiNFO labels
    for key in sorted(keys):
        if key.startswith("HW:"):
            raw[key] = [key[3:]]
        elif key in LABELS:
            raw[key] = LABELS[key]
        elif key in DERIVED:
            raw.setdefault(DERIVED[key][0], LABELS.get(DERIVED[key][0], []))
    sensor_ms = []
    for i in range(LABEL_SLOTS if raw else 0):
        sensor_ms.append(f"[mLabel{i}]\nMeasure=Registry\nRegHKey=HKEY_CURRENT_USER\nRegKey=Software\\HWiNFO64\\VSB\nRegValue=Label{i}\n")
    if raw:
        sensor_ms.append("[mMap]\nMeasure=Script\nScriptFile=#@#map.lua\n")
    for key in raw:
        variables[f"idx_{safe(key)}"] = "-1"
        sensor_ms.append(f"""[r_{safe(key)}]
Measure=Registry
RegHKey=HKEY_CURRENT_USER
RegKey=Software\\HWiNFO64\\VSB
RegValue=ValueRaw#idx_{safe(key)}#
DynamicVariables=1
""")
    sensor_ms.append("[mMemUsed]\nMeasure=PhysicalMemory\n\n[mMemTotal]\nMeasure=PhysicalMemory\nTotal=1\n")
    for key in sorted(keys):
        if key in raw:
            f = f"r_{safe(key)}"
        elif key in DERIVED:
            f = f"r_{safe(DERIVED[key][0])}{DERIVED[key][1]}"
        elif key in MEM:
            f = MEM[key]
        elif key.startswith(("GAME_", "NP_")):     # numeric value set by game.lua / np.lua
            variables.setdefault(key, "0")
            f = f"#{key}#\nDynamicVariables=1"
        else:
            print(f"warning: no data source for {key}; it will show 0")
            f = "0"
        conds = ""
        for n, ((k, thr), acts) in enumerate(sorted((kv for kv in warn.items() if kv[0][0] == key), key=lambda kv: kv[0][1])):
            sfx = "" if n == 0 else str(n + 1)
            conds += (f"IfCondition{sfx}=v_{safe(key)} >= {thr:g}\n"
                      f"IfTrueAction{sfx}={''.join(a for a, _ in acts)}\n"
                      f"IfFalseAction{sfx}={''.join(b for _, b in acts)}\n")
        sensor_ms.append(f"[v_{safe(key)}]\nMeasure=Calc\nFormula={f}\n{conds}")

    lua_want = ",\n".join(f'  {safe(k)} = {{{", ".join(json.dumps(l.lower()) for l in v)}}}' for k, v in raw.items())
    with open(os.path.join(res, "map.lua"), "w", encoding="utf-8", newline="\n") as fh:
        fh.write(f"""-- Maps HWiNFO gadget labels to their registry index (HKCU\\Software\\HWiNFO64\\VSB) every update.
WANT = {{
{lua_want}
}}
LAST = {{}}
function Update()
  local found = {{}}
  for i = 0, {LABEL_SLOTS - 1} do
    local m = SKIN:GetMeasure('mLabel' .. i)
    local s = m and m:GetStringValue() or ''
    if s ~= '' and found[string.lower(s)] == nil then found[string.lower(s)] = i end
  end
  for key, list in pairs(WANT) do
    local idx = -1
    for _, l in ipairs(list) do if found[l] then idx = found[l]; break end end
    if LAST[key] ~= idx then SKIN:Bang('!SetVariable', 'idx_' .. key, idx); LAST[key] = idx end
  end
  return 0
end
""")

    if auto:
        copy_res("game.lua", out)
        sensor_ms.append(r"""[m_FPSPROC]
; the program PresentMon is following (the focused app), from the FPS sensor's name "PresentMon [game.exe]"
Measure=Registry
RegHKey=HKEY_CURRENT_USER
RegKey=Software\HWiNFO64\VSB
RegValue=Sensor#idx_FPS#
DynamicVariables=1
RegExpSubstitute=1
Substitute="^(?:PresentMon \[(.+)\].*|.*)$":"\1"
""")

    # ---- weather: weather.ps1 fetches it (Open-Meteo, falling back to MET Norway; no API keys) into a cache
    # outside the skin folder; wx.lua turns it into WX_* variables
    if weather:
        for k in sorted(weather):
            variables[k] = "4" if k.endswith("_ICON") else "0" if k in wx_num else "--"
        with open(data_src("weather.json"), encoding="utf-8") as fh:
            loc = json.load(fh)
        for f in ("wx.lua", "weather.ps1"):
            copy_res(f, out)
        cache = rt("wx-cache.json")
        sensor_ms.append(f"""[mWxFetch]
Measure=Plugin
Plugin=RunCommand
Program=powershell.exe
Parameter=-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "#CURRENTPATH#res\\weather.ps1" -Config "{rt('weather.json')}" -Out "{cache}" -Lat "#WxCityLat#" -Lon "#WxCityLon#"
DynamicVariables=1
State=Hide
OutputType=ANSI
Timeout=60000
FinishAction=[!CommandMeasure mWxScript "Parse()"]

[mWxScript]
Measure=Script
ScriptFile=#CURRENTPATH#res\\wx.lua
Cache={cache}
RefreshMinutes={int(loc.get("refresh_minutes", 15))}
""")

    # ---- paging: swiping left/right loads the next/previous page (.ini) of this config
    n = len(pages)
    swipe = ""
    if n > 1:
        nxt, prv = pages[(index + 1) % n], pages[(index - 1) % n]
        # Windows doesn't always deliver the touch release (a left-to-right swipe on the Y70 sends only the
        # press), so the finger is also tracked while it moves: invisible vertical strips report their
        # position on mouse-over, and the page changes as soon as the finger has travelled far enough.
        swipe = ('LeftMouseDownAction=[!SetVariable SwipeX0 "$MouseX$"][!SetVariable SwipeX1 "$MouseX$"]'
                 '[!SetVariable SwipeOn 1][!UpdateMeasure mSwipeAge]\n'
                 'LeftMouseUpAction=[!SetVariable SwipeX1 "$MouseX$"][!UpdateMeasure mSwipe][!SetVariable SwipeOn 0]\n')
        variables.update({"SwipeX0": "0", "SwipeX1": "0", "SwipeOn": "0", "SwipeMin": str(round(150 * scale))})
        hook = ('[!CommandMeasure mGame "Swiped()"]' if auto else '') + ('[!CommandMeasure mMusic "Swiped()"]' if music else '')
        measures.append(f"""[mSwipe]
Measure=Calc
Formula=#SwipeOn# * (#SwipeX1#-#SwipeX0#)
DynamicVariables=1
UpdateDivider=-1
IfConditionMode=1
IfCondition=mSwipe < -#SwipeMin#
IfTrueAction=[!SetVariable SwipeOn 0]{hook}[!ActivateConfig "#CURRENTCONFIG#" "{nxt}.ini"]
IfCondition2=mSwipe > #SwipeMin#
IfTrueAction2=[!SetVariable SwipeOn 0]{hook}[!ActivateConfig "#CURRENTCONFIG#" "{prv}.ini"]

[mSwipeAge]
; a press with no release stops counting as a swipe after ~2 s
Measure=Calc
Formula=#SwipeOn# = 1 ? mSwipeAge + 1 : 0
DynamicVariables=1
IfCondition=mSwipeAge > 2
IfTrueAction=[!SetVariable SwipeOn 0]
""")
        strips = 16
        sw_ = W / strips
        for j in range(strips):
            meters.append(f"""[swipeStrip{j}]
Meter=Image
SolidColor=0,0,0,1
X={round(j * sw_)}
Y=0
W={round((j + 1) * sw_) - round(j * sw_)}
H={H}
MouseOverAction=[!SetVariable SwipeX1 "{round((j + 0.5) * sw_)}"][!UpdateMeasure mSwipe]
""")
        if tz:
            # tap on the clock (released within SwipeMin of where it was pressed): show the other zone, and
            # the zone's name in place of the day; mTzBack switches back after tz["seconds"]
            # the day line keeps the day (that zone's) and adds the zone's name: "Thursday · Buenos Aires"
            # The city is the AltCity setting (settings page); tz.lua keeps AltTZ at its offset right now, from
            # Windows' time zone data (tz_table). The HTML's data-tz / data-tz-name are the fallback.
            to_alt = "".join(f'[!SetVariable {fv} "{fmt} · #AltCity#"]' for fv, fmt in tz_day)
            to_local = "".join(f'[!SetVariable {fv} "{fmt}"]' for fv, fmt in tz_day)
            refresh = "[!UpdateMeasureGroup Clock][!UpdateMeter *][!Redraw]"
            variables.update({"ClockTZ": "local", "ClockAlt": "0", "AltTZ": tz["offset"]})
            copy_res("tz.lua", out)
            zones = ";".join(f"{c}@" + ",".join(f"{a}:{o:g}" for a, o in lst) for c, lst in tz_table().items())
            measures.append(f"[mAltTz]\n; the second clock's offset now (AltTZ), for the AltCity setting\nMeasure=Script\n"
                            f"ScriptFile=#CURRENTPATH#res\\tz.lua\nZones={zones}\nDefault={tz['offset']}\n")
            measures.append(f"""[mTzTap]
Measure=Calc
Formula=#SwipeOn# * (Abs(#SwipeX1#-#SwipeX0#) < #SwipeMin#)
DynamicVariables=1
UpdateDivider=-1
IfConditionMode=1
IfCondition=mTzTap = 1
IfTrueAction=[!SetVariable ClockAlt 0][!UpdateMeasure mTzBack][!SetVariable ClockAlt 1][!SetVariable ClockTZ #AltTZ#]{to_alt}{refresh}

[mTzBack]
; counts the seconds the other zone has been shown (a new tap starts the count again)
Measure=Calc
Formula=#ClockAlt# = 1 ? mTzBack + 1 : 0
DynamicVariables=1
IfCondition=mTzBack >= {tz["seconds"]}
IfTrueAction=[!SetVariable ClockAlt 0][!SetVariable ClockTZ local]{to_local}{refresh}
""")
            meters.extend(tz_area)
        r_dot, gap = 9 * scale, 40 * scale
        cx0, cy = W / 2 - gap * (n - 1) / 2, H - 50 * scale
        shapes = "\n".join(
            f"Shape{'' if j == 0 else j + 1}=Ellipse {cx0 + j * gap:.1f},{cy:.1f},{r_dot:.1f} | StrokeWidth 0 | "
            f"Fill Color {tc((61, 224, 255, 255) if j == index else (58, 74, 98, 255))}" for j in range(n))
        meters.append(f"[pageDots]\nMeter=Shape\nX=0\nY=0\n{shapes}\n")
        if gear:
            # the settings gear, right of the dots: remembers this page for the settings page's Done button
            # a solid gear (Shape meter): a disc with eight teeth (four bars across it) and a hole in the middle
            gd, ga = 48 * scale, 150 * scale
            gx = cx0 + gap * (n - 1) + 110 * scale
            t, m = 0.24 * gd, gd / 2
            bars = "".join(f"Shape{i + 2}=Rectangle {m - t / 2:.2f},0,{t:.2f},{gd:.2f},{0.05 * gd:.2f} | Rotate {a}\n"
                           for i, a in enumerate((0, 45, 90, 135)))
            buttons.append(f"""[gear]
Meter=Shape
X={gx - m:.1f}
Y={cy - m:.1f}
Shape=Ellipse {m:.2f},{m:.2f},{0.37 * gd:.2f} | Fill Color {tc((61, 224, 255, 255))} | StrokeWidth 0
{bars}Shape6=Ellipse {m:.2f},{m:.2f},{0.14 * gd:.2f}
Shape7=Combine Shape | Union Shape2 | Union Shape3 | Union Shape4 | Union Shape5 | Exclude Shape6
AntiAlias=1

[gearTap]
Meter=Image
SolidColor=0,0,0,1
X={gx - ga / 2:.1f}
Y={cy - ga / 2:.1f}
W={ga:.1f}
H={ga:.1f}
LeftMouseUpAction=[!SetVariable SwipeOn 0][!WriteKeyValue Variables SettingsReturn "{name}" "{settings_rt()}"][!ActivateConfig "#CURRENTCONFIG#" "Settings.ini"]
""")

    if np_ or buttons:
        # now playing: nowplaying.ps1 reads Windows' media controls into res\np\np.txt while this page is shown;
        # np.lua turns it into NP_* variables; MediaKey / Win7Audio handle the buttons and the volume
        for f in ("np.lua", "nowplaying.ps1"):
            copy_res(f, out)
        for k in np_:
            variables[k] = {"NP_TITLE": "Nothing playing", "NP_PLAYICON": "", "NP_VOLICON": "",
                            "NP_PROGRESS": "0", "NP_VOLPCT": "0"}.get(k, "")
        # light mode: a page without the big NP_ART cover (e.g. the gaming page's now-playing strip) skips the
        # PowerShell helper and reads npwatch.exe's status file and history thumbnails instead
        np_lite = "NP_ART" not in np_ and bool(watch)
        art = np_.get("NP_ART", "733x733")
        idle_art = ""
        idle_msrc = os.path.join(ROOT, "screens", "idle-music.html")
        if "NP_ART" in np_ and os.path.exists(idle_msrc):
            # original artwork for the cover while nothing plays (or a track has no artwork)
            aw_, ah_ = art.split("x")
            chrome([f"--window-size={aw_},{ah_}", "--default-background-color=00000000",
                    f"--screenshot={os.path.join(res, 'idle_art.png')}",
                    "file:///" + idle_msrc.replace("\\", "/")])
            variables["NP_ART"] = idle_art = "#@#idle_art.png"
        if not np_lite:
            sensor_ms.append(f"""[mNPHelper]
Measure=Plugin
Plugin=RunCommand
Program=powershell.exe
Parameter=-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "#CURRENTPATH#res\\nowplaying.ps1" -Out "#CURRENTPATH#res\\np" -Heartbeat "#CURRENTPATH#res\\np\\heartbeat" -Art {art}
State=Hide
OutputType=ANSI
""")
        sensor_ms.append(f"""[mMediaKey]
Measure=Plugin
Plugin=MediaKey

[mVol]
Measure=Plugin
Plugin=Win7AudioPlugin
""")
        os.makedirs(os.path.join(out, "res", "np"), exist_ok=True)
        measures.append(f"""[mNP]
Measure=Script
ScriptFile=#CURRENTPATH#res\\np.lua
Info=#CURRENTPATH#res\\np\\np.txt
Heartbeat=#CURRENTPATH#res\\np\\heartbeat
History={rt("np-history") if watch else ""}
HistoryRows={sum(1 for k in np_ if re.fullmatch(r"NP_H\d+_TITLE", k))}
Light={1 if np_lite else 0}
Status=#CURRENTPATH#res\\npstatus.txt
IdleArt={idle_art}
""")

    info_opt = ""
    if auto and game:
        # game name, Steam playtime and artwork for this page's GAME_* slots (looked up by gameinfo.ps1)
        shutil.copy(os.path.join(HERE, "gameinfo.ps1"), os.path.join(out, "res", "gameinfo.ps1"))
        for k in game:
            variables[k] = "No game running" if k == "GAME_NAME" else ""
        idle_opt = ""
        idle_src = os.path.join(ROOT, "screens", "idle-hero.html")
        if "GAME_HERO" in game and os.path.exists(idle_src):
            # original artwork for the banner while no game runs (or the game has no Steam artwork)
            iw, ih = game["GAME_HERO"].split("x")
            url_ = "file:///" + idle_src.replace("\\", "/")
            # the banner without the controller...
            chrome([f"--window-size={iw},{ih}", "--default-background-color=00000000",
                    f"--screenshot={os.path.join(res, 'idle_hero.png')}", url_ + "?part=bg"])
            # ...and the controller as a strip of IDLE_FRAMES frames, cut to IDLE_BOX (design px of the 952x330 art),
            # played on top of it by [idlePad] while no game is shown
            hx, hy, hw, hh = img_pos["GAME_HERO"]
            sx = hw / 952
            bx, by, bw, bh = IDLE_BOX
            pw, ph = round(bw * sx), round(bh * sx)
            chrome([f"--window-size={pw * IDLE_FRAMES},{max(ph, 100)}", "--default-background-color=00000000",
                    f"--screenshot={os.path.join(res, 'idle_pad.png')}",
                    url_ + f"?frames={IDLE_FRAMES}&box={bx},{by},{bw},{bh}&px={pw}"])
            meters.append(f"""[idlePad]
; the idle banner's animated controller (game.lua shows it with the idle banner and hides it for a game)
Meter=Image
ImageName=#@#idle_pad.png
ImageCrop=([mIdleFrame]*{pw}),0,{pw},{ph}
X={hx + round(bx * sx)}
Y={hy + round(by * sx)}
W={pw}
H={ph}
DynamicVariables=1
UpdateDivider=1
Group=IdleAnim
""")
            measures.append(f"[mIdleFrame]\n; the idle controller's animation frame (settings: AnimGaming=0 holds it still)\n"
                            f"Measure=Calc\nFormula=#AnimGaming# = 1 ? (mIdleFrame + 1) % {IDLE_FRAMES} : 0\nUpdateDivider=1\n")
            idle_anim = True
            variables["GAME_HERO"] = "#@#idle_hero.png"
            idle_opt = "IdleHero=#@#idle_hero.png\nIdleAnim=1\n"
        # game-art\ (next to known-games.txt): your own banner (<exe name>.jpg/.png) and logo (<exe name>-logo.png)
        art_dir = rt("game-art")
        os.makedirs(data_src("game-art"), exist_ok=True)
        sizes = (f'-Hero {game.get("GAME_HERO", "952x330")} -Logo {game.get("GAME_LOGO", "440x200")} '
                 f'-Art "{art_dir}"')
        measures.append(f"""[mGameInfo]
Measure=Plugin
Plugin=RunCommand
Program=powershell.exe
Parameter=-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "#CURRENTPATH#res\\gameinfo.ps1" -Exe "none" -Out "#CURRENTPATH#res\\game" {sizes}
State=Hide
OutputType=ANSI
DynamicVariables=1
FinishAction=[!CommandMeasure mGame "InfoReady()"]
""")
        info_opt = (f'InfoArgs=-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "#CURRENTPATH#res\\gameinfo.ps1" '
                    f'-Exe "%EXE%" -Out "#CURRENTPATH#res\\game" {sizes}\nInfoFile=#CURRENTPATH#res\\game\\info.txt\n' + idle_opt)
    if auto:
        measures.append(f"""[mGameRunning]
; 1 while the detected game's process is running (game.lua sets ProcessName)
Measure=Plugin
Plugin=Process
ProcessName=none.exe

[mGame]
Measure=Script
ScriptFile=#CURRENTPATH#res\\game.lua
ThisPage={name}
GamePage={page_name(auto.get("page", "gaming.html"))}
GpuLoad=#GpuLoad#
EnterSeconds={auto.get("enter_seconds", 5)}
ExitSeconds={auto.get("exit_seconds", 30)}
IgnoreFile={rt(IGNOREFILE)}
GameFolders={"|".join(auto.get("game_folders", []))}
State=#CURRENTPATH#res\\autoswitch.state
DefaultPage={DEFAULT_PAGE}
{watch or "Known=" + rt("known-games.txt") + chr(10)}{info_opt}""")
        kp = data_src("known-games.txt")
        if not os.path.exists(kp):
            with open(kp, "w", encoding="utf-8", newline="\n") as fh:
                fh.write("# Games the Hyte screen switches to the gaming page for within ~1 s (one exe per line).\n"
                         "# New games are added automatically the first time they're detected. Delete a line to forget one.\n")

    if music:
        copy_res("music.lua", out)
        gp = page_name(auto.get("page", "gaming.html")) if auto else ""
        measures.append(f"""[mMusic]
; npwatch.exe writes what Windows' media controls are playing to res\\npstatus.txt
Measure=Script
ScriptFile=#CURRENTPATH#res\\music.lua
{watch}ThisPage={name}
MusicPage={page_name(music.get("page", "music.html"))}
GamePage={gp}
EnterSeconds={music.get("enter_seconds", 3)}
ExitSeconds={music.get("exit_seconds", 30)}
ClosedSeconds={music.get("closed_seconds", 3)}
MusicOnly={1 if music.get("music_only", True) else 0}
State=#CURRENTPATH#res\\music.state
GameState={"#CURRENTPATH#res" + chr(92) + "autoswitch.state" if auto else ""}
Log={rt("autoswitch.log")}
""")

    # data-group: the group's art image goes first (under its live meters), and every meter placed inside the
    # group's area joins the Rainmeter group. data-show="playing" groups start hidden; np.lua shows them while
    # something is playing.
    idle_groups = []
    if groups:
        def tag(sec):
            m = re.search(r"^X=(-?\d+)\s*$.*?^Y=(-?\d+)\s*$", sec, re.M | re.S)
            if not m:
                return sec
            px, py = int(m.group(1)), int(m.group(2))
            for gr in groups:
                if gr["x"] <= px <= gr["x"] + gr["w"] and gr["y"] <= py <= gr["y"] + gr["h"]:
                    return sec.rstrip("\n") + f"\nGroup={gr['name']}\n" + ("Hidden=1\n" if gr.get("show") else "")
            return sec
        meters[:] = [tag(sec) for sec in meters]
        buttons[:] = [tag(sec) for sec in buttons]
        for gr in reversed(groups):
            meters.insert(0, f"[group_{gr['name']}]\nMeter=Image\nImageName={ti('group_' + gr['name'])}\nX={gr['x']}\nY={gr['y']}\n"
                             f"W={gr['w']}\nH={gr['h']}\nGroup={gr['name']}\n" + ("Hidden=1\n" if gr.get("show") else ""))
        idle_groups = [gr["name"] for gr in groups if gr.get("show") == "playing"]
        measures[:] = [sec.rstrip("\n") + f"\nIdleHide={','.join(idle_groups)}\n" if sec.startswith("[mNP]") else sec
                       for sec in measures]

    # a visualizer redraws at ~30 fps; everything else still updates once a second (DefaultUpdateDivider)
    # animated weather icons step one frame every 1/WX_FPS s
    fps = 30 if visual else WX_FPS if (anim_icons or idle_anim) else 1
    if idle_anim and fps != WX_FPS:
        measures[:] = [m.replace("\nUpdateDivider=1\n", f"\nUpdateDivider={round(fps / WX_FPS)}\n")
                       if m.startswith("[mIdleFrame]") else m for m in measures]
    if anim_icons:
        # settings: AnimWeather=0 holds every icon on its first frame
        measures.append(f"[mWxFrame]\n; the weather icons' animation frame\nMeasure=Calc\n"
                        f"Formula=#AnimWeather# = 1 ? (mWxFrame + 1) % {WX_FRAMES} : 0\n"
                        f"UpdateDivider={max(1, round(fps / WX_FPS))}\n")
    if visual:
        # settings: AnimMusic=0 switches the spectrum off (its measures stop listening, its bars hide)
        measures.append("[mSpectrumOff]\nMeasure=Calc\nFormula=#AnimMusic#\nUpdateDivider=-1\n"
                        "IfCondition=mSpectrumOff = 0\nIfTrueAction=[!DisableMeasureGroup Spectrum][!HideMeterGroup Spectrum][!Redraw]\n")
        visual[:] = [v.rstrip("\n") + "\nGroup=Spectrum\n" for v in visual]
        meters[:] = [m.rstrip("\n") + "\nGroup=Spectrum\n" if m.startswith(("[vis", "[visr")) else m for m in meters]
    if settings_ui:
        # the settings page: settings.lua changes and saves settings.inc
        copy_res("settings.lua", out)
        measures.append(f"[mSettings]\nMeasure=Script\nScriptFile=#CURRENTPATH#res\\settings.lua\nFile={settings_rt()}\n"
                        f"StartFile=#CURRENTPATH#res\\rainmeter-start.txt\n"
                        f"Toggles={','.join(settings_ui.get('toggles', []))}\n"
                        + "".join(f"Choices_{v}={'|'.join(CHOICES[v])}\n" for v in sorted(settings_ui.get('cycles', ()))
                                  if v in CHOICES)
                        # choices that are places: their coordinates (settings.lua also saves <setting>Lat/Lon)
                        + "".join(f"Coords_{v}={'|'.join(f'{c}={la},{lo}' for c, (la, lo) in COORDS[v].items())}\n"
                                  for v in sorted(settings_ui.get('cycles', ())) if v in COORDS))
        if fps != WX_FPS:
            meters[:] = [m.replace("\nUpdateDivider=1\n", f"\nUpdateDivider={round(fps / WX_FPS)}\n")
                         if m.startswith("[icon") else m for m in meters]
    measures = visual + measures
    # place.lua: the skin puts itself on the Y70 screen when it loads (and moves there if that screen moved)
    copy_res("place.lua", out)
    measures.append(f"[mPlace]\nMeasure=Script\nScriptFile=#CURRENTPATH#res\\place.lua\nRole=page\nSize={W}x{H}\nUpdateDivider=-1\n")

    def dyn(block):
        parts = re.split(r"(?m)^(?=\[)", block)
        return "".join(q.replace("\n", "\nDynamicVariables=1\n", 1) if "[#DarkTheme]]" in q and "DynamicVariables=1" not in q
                       else q for q in parts)
    meters[:] = [dyn(m_) for m_ in meters]
    buttons[:] = [dyn(b_) for b_ in buttons]
    ini = f"""; ResMon {name}: generated by rainmeter/build_skin.py from {os.path.relpath(design, ROOT)}. Edit the design and rebuild.
[Rainmeter]
Update={round(1000 / fps)}
AccurateText=1
DefaultUpdateDivider={fps}
BackgroundMode=1
OnRefreshAction=[!SetVariable Fill "#@#fill_bg" "{BACKDROP}"][!UpdateMeter fill "{BACKDROP}"][!Redraw "{BACKDROP}"]
{swipe}
[Metadata]
Name=ResMon {name}
Information=Live sensor screen for the HYTE Y70 Touch ({W}x{H}). Data from HWiNFO64 gadget export.

[Variables]
{chr(10).join(f'{k}={v}' for k, v in variables.items())}
{include_settings()}

; the static art in three layers. The page background (fill_bg.png) is drawn by the backdrop skin underneath
; (OnRefreshAction hands it this page's), the panels' fill is faded by the see-through settings, and the rest is solid.
[fillBg]
Meter=Image
; an all-but-invisible fill: Rainmeter passes clicks through fully transparent pixels, so see-through parts
; would otherwise ignore taps and swipes
SolidColor=0,0,0,1
X=0
Y=0
W={W + 1}
H={H + 1}

[fillPanels]
Meter=Image
ImageName={ti('fill_panels')}
ImageAlpha=(#Transparency# = 1 ? Round(Clamp(#PanelOpacity#, 0, 100) * 2.55) : 255)
DynamicVariables=1
X=0
Y=0
W={W}
H={H}

[bg]
Meter=Image
ImageName={ti('background')}
DynamicVariables=1
X=0
Y=0
W={W}
H={H}

{chr(10).join(sensor_ms)}
{chr(10).join(measures)}
{chr(10).join(meters + buttons)}"""
    # Rainmeter resolves #@# to the config root's @Resources; keep everything inside this skin folder instead
    ini = ini.replace("#@#", f"#CURRENTPATH#res\\{name}\\")
    with open(os.path.join(out, f"{name}.ini"), "w", encoding="utf-16") as fh:
        fh.write(ini)
    print(f"Built page {index + 1}/{len(pages)} {os.path.join(out, name + '.ini')}  ({len(g['runs'])} text, {len(g['meters'])} meters, {len(raw)} HWiNFO sensors)")
    return name


def build_pages(designs, size=None, skins=None, config="Screen"):
    """Every design becomes a page (.ini) of one Rainmeter config, ResMon\\<config> (Screen). Swipe to change page.
    skins: the ResMon folder to write into (rainmeter/ResMon)."""
    skins = skins or os.path.join(HERE, "ResMon")
    out = os.path.join(skins, config)
    shutil.rmtree(out, ignore_errors=True)
    os.makedirs(os.path.join(out, "res"))
    ensure_settings()
    ensure_ignored()
    names = [page_name(d) for d in designs]
    # screens/settings.html: a page outside the swipe order, opened by the gear next to the page dots
    sp = os.path.join(ROOT, "screens", "settings.html")
    gear = len(designs) > 1 and os.path.exists(sp)
    for i, d in enumerate(designs):
        build(d, size, out, names, i, gear)
    if gear:
        build(sp, size, out, [page_name(sp)], 0)
    write_backdrop(names[0], skins, config)
    return names


def write_backdrop(first, skins=None, config="Screen"):
    """ResMon\\Backdrop: the page background, in its own config underneath ResMon\\Screen. It stays loaded while
    the pages change (a swipe unloads one .ini and loads the next), so the wallpaper doesn't flash through; each page
    hands it its own background as it loads. Faded by the see-through settings like the panels."""
    skins = skins or os.path.join(HERE, "ResMon")
    bd = os.path.join(skins, "Backdrop")
    shutil.rmtree(bd, ignore_errors=True)
    os.makedirs(bd)
    # place.lua for the backdrop, shared by every build in ResMon\\@Resources
    os.makedirs(os.path.join(skins, "@Resources"), exist_ok=True)
    shutil.copy(os.path.join(HERE, "place.lua"), os.path.join(skins, "@Resources", "place.lua"))
    with open(os.path.join(bd, "Backdrop.ini"), "w", encoding="utf-16") as fh:
        fh.write(f"""; ResMon backdrop: generated by rainmeter/build_skin.py. The pages set Fill to their own background.
[Rainmeter]
Update=-1
BackgroundMode=1

[Variables]
Fill=#SKINSPATH#ResMon\\{config}\\res\\{first}\\fill_bg
; the theme's picture (settings: DarkTheme): fill_bg.png (dark) or fill_bg_l.png (light)
thPng1=.png
thPng0=_l.png
{include_settings()}

[fill]
Meter=Image
ImageName=#Fill#[#thPng[#DarkTheme]]
ImageAlpha=(#Transparency# = 1 ? Round(Clamp(#BgOpacity#, 0, 100) * 2.55) : 255)
DynamicVariables=1
X=0
Y=0

[mPlace]
; puts the backdrop on the Y70 screen, at the bottom and click-through (see place.lua)
Measure=Script
ScriptFile=#SKINSPATH#ResMon\\@Resources\\place.lua
Role=backdrop
UpdateDivider=-1
""")


if __name__ == "__main__":
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("designs", nargs="*", help="pages in swipe order (default: screens/home.html)")
    ap.add_argument("--size", help="skin size in Rainmeter's (logical) pixels, e.g. 733x2560")
    ap.add_argument("--default", help="design of the page to show when Rainmeter starts (default: the first)")
    a = ap.parse_args()
    init_data()
    designs = a.designs or [os.path.join(ROOT, "screens", "home.html")]
    DEFAULT_PAGE = page_name(a.default or designs[0])
    names = build_pages(designs, tuple(int(v) for v in a.size.lower().split("x")) if a.size else None)
    print("PAGES=" + ",".join(names))
