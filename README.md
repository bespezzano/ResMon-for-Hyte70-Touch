# ResMon: live sensor screens for the HYTE Y70 Touch

This adapts [biltrex/lconnect-screen-template](https://github.com/biltrex/lconnect-screen-template) to the
HYTE Y70 Touch display. That project turns HTML designs into L-Connect 3 templates, but L-Connect only drives
Lian Li screens. The Y70 Touch is an ordinary Windows monitor (1100×3840 portrait), so here the HTML designs are
turned into a Rainmeter skin instead.

- **Same design contract.** Designs use the template's `data-lc` slots (`text`, `label`, `bar`, `slider`, `arc`,
  `chart`, `needle`, `ring`) and L-Connect sensor keys (`CPUTEMP`, `GPULOAD`, `RAM_GB`, `TIME`…), so the
  template's design reference and its "Brief for Claude Design" still apply. Use a portrait canvas of 1100×3840
  instead of 1920×480.
- **Data comes from HWiNFO64.** The skin reads the values HWiNFO exports to the registry (Sensor settings →
  pick a sensor → *Report value in Gadget*).

## Files

| File | What it does |
|---|---|
| `screens/*.html` | The designs, one per page |
| `pages.txt` | Which designs become pages, in swipe order, and the page shown first |
| `install-skin.ps1` | Builds the skin and installs it on the portrait monitor |
| `rainmeter/build_skin.py` | Turns the designs into the skin (one `.ini` per page) |
| `rainmeter/sensors.py` | The HWiNFO sensor names behind each sensor key (`CPUTEMP`, `GPULOAD`…) |
| `lc-live.js` | Draws a design's slots: the builder uses it, and a design opened in a browser shows as a preview with sample values |
| `rainmeter/package.py` | Builds the skin package to share (`dist/ResMon_<version>.rmskin`) |
| `rainmeter/start.lua`, `rainmeter/setup.ps1` | The package's starter skin: sets up the data folder and loads the build for the screen |

## Download

To just use the skin, download `ResMon_<version>.rmskin` from the
[Releases](https://github.com/bespezzano/ResMon-for-Hyte70-Touch/releases) page and double-click it. You need
[Rainmeter](https://www.rainmeter.net) 4.5 or later and [HWiNFO64](https://www.hwinfo.com) with the sensors reported
to the gadget (see below). The rest of this README is about building it yourself and changing the designs.

## Install from the source

Building needs Python 3 and Google Chrome or Microsoft Edge (the builder draws the designs with it headless).

```powershell
powershell -ExecutionPolicy Bypass -File .\install-skin.ps1
```

Run it again after changing a design, `pages.txt` or the builder. Rainmeter brings the skin back at sign-in.

## Sharing: the skin package

```powershell
python -I rainmeter\package.py --version 1.0 --author "Your name"
```

This writes `dist/ResMon_1.0.rmskin`. Someone with Rainmeter 4.5 or later double-clicks it, and Rainmeter's
installer puts it in their Skins folder and loads the starter skin, `ResMon\Start`. They need HWiNFO64 with the
sensors reported to the gadget (see above), but not Python, Chrome or this project.

- **One build per screen size.** Rainmeter works in Windows' scaled pixels, so the package holds the pages built for
  each Y70 model at the usual scalings, as configs named by size: the 1st gen at 100 to 200 % (`1100x3840`,
  `880x3072`, `733x2560`, `629x2194`, `550x1920`) and the Infinite models at 100 to 150 % (`688x2560` / `682x2560`,
  `550x2048` / `546x2048`, `459x1707` / `455x1707`). The starter finds the Y70 like `place.lua` does, loads the build
  closest to its size and the backdrop, unloads any other build, and unloads itself. After changing the screen's
  scaling, load `ResMon\Start` again from Rainmeter's Manage window.
- **Data folder.** The package's pages keep everything they save in `%APPDATA%\Rainmeter\ResMon`: settings, the game
  lists, `weather.json`, the weather cache, the music history, the auto-switch log and `game-art`. On first run the
  starter copies its starting files there (`setup.ps1`), keeping any already there, so reinstalling or updating keeps
  a user's settings. The settings page's **Open** shows that folder.
- **Nothing of yours goes in.** The starting files are generic: weather on Automatic (London when Windows can't say
  where the PC is) with 17 world cities to pick from, London on the second clock, no known games. The project's
  ignored-apps list and auto-switch rules are copied as they are. Before writing the file, `package.py` searches the
  package's text for your user name, this folder's path and your own weather places, and stops if it finds any.
- `--sizes 1100x3840,682x2560` builds only those sizes (quicker, for testing). Each size takes about 35 s, and the
  whole package is about 50 MB.

Your own install (`install-skin.ps1`) keeps its data in this folder as before. Installing a package on this PC
replaces it in the Skins folder (Rainmeter keeps a backup), and running `install-skin.ps1` puts yours back.

## The skin

**Settings page:** tap the gear next to the page dots. It isn't in the swipe order; Done goes back to the page you
came from. It has:
- **Dark theme** on/off. Off is the light theme: light panels and background, dark text, deeper accent colours. The
  light theme is made from the same designs by flipping each colour's lightness and keeping its hue (lc-live.js
  with `&theme=light`; the builder and the Lua scripts flip the skin's own colours the same way). Artwork, game
  banners and weather icons stay as they are. The builder draws each page's art for both themes (files ending in
  `_l` are the light ones), so switching needs no rebuild: the Settings page redraws at once, and the other pages
  open in the new theme. With See-through on and a low Background value, the wallpaper makes the light
  background look grey; a higher Background value keeps it light.
- **See-through** on/off, and how solid the **Background** and the **Panels** are (−/+ in 5 % steps). The desktop
  wallpaper shows through; text, gauges, charts, artwork and the panels' coloured edges stay solid. Changes show at
  once: each page's static art is built as three layers (`fill_bg.png`, `fill_panels.png`, `background.png`) and the
  skin fades the first two. Taps and swipes still work on clear areas (an all-but-invisible fill sits behind everything).
  The page background is drawn by a second config, `ResMon\Backdrop`, underneath the pages (click-through, "bottom"
  position). It stays loaded while pages change, so a swipe doesn't flash the wallpaper; each page hands it its own
  background as it loads. It's a pixel larger than the page, because the display's size in Rainmeter's scaled
  pixels isn't always whole (at 150 % scaling, 1100 / 1.5 = 733.3) and the last fraction of a pixel would otherwise
  show the wallpaper.
- **Fahrenheit** (`TempF`): the weather (`wx.lua` converts the forecast) and the CPU/GPU temperatures in °F. A
  sensor temperature's text goes through a Calc measure (`v_<KEY>_t`); its warning colour and arc keep using °C.
  The unit labels are `data-sensor="TEMP_UNIT"` text, so they switch between °C and °F.
- **Wind in mph** (`WindMph`): the weather page's wind speed in mph instead of km/h (`wx.lua` converts it;
  the unit label is `data-sensor="WIND_UNIT"` text).
- **12-hour clock** (`Clock12`): every page's clock and the second clock show 6:05 instead of 18:05, with a small
  grey AM/PM after the time (placed from the time's width; hidden while the clock is 24-hour). `TIME12` in `build_skin.py` maps each 24-hour format to its 12-hour one.
- **Places**: the **Weather** location (‹ › cycle through **Automatic** and `weather.json`'s `locations`; the
  weather page shows its name, and the forecast is fetched again at once) and the **Second clock** city (17 cities).
- **Animations** per page: the weather icons, the gaming page's idle controller, the music spectrum. A page picks the
  change up when it opens.
- **Game detection**: **GPU load** (`GpuLoad`, − / + in steps of 5 %): a fullscreen app counts as a game while the
  GPU is at least this busy. **Edit** opens `known-games.txt` or `ignored-apps.txt` in Notepad. Changes apply when a
  page opens (tap Done, or swipe).
- **Files**: **Open** opens this folder in Explorer (in a package, the data folder `%APPDATA%\Rainmeter\ResMon`).

The choices are kept in `%APPDATA%\Rainmeter\ResMon\settings.inc` (Rainmeter variables; Rainmeter only lets a skin
save files in its Skins or settings folder, and the Skins copy is replaced on every install). Rebuilding keeps them.
The page's design is `screens/settings.html` (`data-lc="toggle"` switches, `data-action="setting"` −/+ buttons,
`data-sensor="SET_<setting>"` values) and `rainmeter/settings.lua` saves the changes.

`rainmeter/build_skin.py` converts a design into a skin, like the original L-Connect exporter does. Static
art becomes one background image, and each `data-lc` slot becomes a Rainmeter meter: String meters, Bar meters
over a pre-rendered lit-bar image, gradient arcs with a dynamic cover and round end, and Line/Histogram charts.
`install-skin.ps1` rebuilds the skin and installs it as the `ResMon\Screen` config in Rainmeter's
Skins folder, so after editing a design just run it again. Values come from the same HWiNFO registry export;
a small Lua script looks sensors up by label, so reordering HWiNFO's list doesn't break anything.

### Placement and other Y70 models

The skin puts itself on the Y70 (`rainmeter/place.lua`, run by every page and by the backdrop when they load). It
finds the screen by its shape: 3.3 to 4 times taller than wide, which fits all three Y70 Touch generations and no
ordinary monitor (otherwise it uses the tallest portrait monitor). If the skin isn't at that screen's corner, it moves
there and fixes itself in place: the pages in the normal layer, the backdrop at the bottom and click-through. So a
changed monitor arrangement is picked up the next time a page opens, and `install-skin.ps1` only installs and
loads the skin. If the page was built for another size than the screen's, Rainmeter's log says so ("rebuild it for
this screen").

| Model | Resolution | Height ÷ width |
|---|---|---|
| Y70 Touch (1st gen) | 1100 × 3840 | 3.49 |
| Y70 Touch Infinite (2nd gen) | 688 × 2560 | 3.72 |
| Y70 Touch Infinite (3rd gen) | 682 × 2560 | 3.75 |

The designs are 1100 × 3840. On a screen that's taller in proportion (the Infinite models), the builder makes the
page taller to match, and the extra height is shared equally by the gaps between panels and the space above the
page dots (`&tall=` in `lc-live.js`); the header and the first panel stay put. To build for another model's size
on this PC (to check how it looks), run `install-skin.ps1 -Size 682x2560`; the skin then fills that much of the
screen. Run `install-skin.ps1` without `-Size` to go back.

### Pages and swiping

Every design listed in `pages.txt` becomes a page of the `ResMon\Screen` skin. Swipe left for the next page
and right for the previous one (a drag of about 150 px; taps do nothing). Dots at the bottom show the current
page. To add or reorder pages, edit `pages.txt` and run `install-skin.ps1` again. The
`default=home.html` line in `pages.txt` picks the page shown after installing and whenever Rainmeter starts
(for example after a reboot). Without it, the first page is used.

Touching a screen makes Windows move the mouse pointer to where you touched. So the watcher (`npwatch.exe`) puts the
pointer back where it was once you lift your finger, which leaves your mouse on the main monitor after a
swipe. It recognises touch by the signature Windows puts on touch-made mouse events, and only watches mouse input
without changing it. A real mouse is never moved. Each page
is its own `.ini`, so charts start fresh when you switch to a page.

**Tap the clock** (Home and Weather) to see another city's time for 5 seconds (Buenos Aires unless you pick
another on the settings page's **Second clock**). The day line shows that city's day and its name ("Wednesday ·
Buenos Aires"), and the date is its date. Then it switches back to local time; another tap starts the 5 seconds
again. A swipe that starts on the clock still changes the page. Daylight saving is handled: when the skin is built,
`rainmeter/tzdump.ps1` reads each city's UTC offset changes for the next 3 years from Windows' time zone data
(rebuilding extends it), and `tz.lua` picks the one in force. The cities are `CITIES` in `build_skin.py` (name and
Windows time zone id). The tap area is in the page's HTML:
`<div data-lc="button" data-action="timezone" data-tz="-3" data-tz-name="Buenos Aires" data-seconds="5">`
(`data-tz` is only used if the time zone data can't be read).
`data-tz` is the zone's hours from UTC, used without daylight saving (Argentina has none). On a page with this
area, every clock and date measure follows the `ClockTZ` variable.

### Automatic gaming page

When a game is focused, the screen switches to the gaming page by itself (`rainmeter/game.lua`, settings in
`autoswitch.json`). A "game" is the program HWiNFO's PresentMon sensor is following (the focused app) when it
isn't in `ignored-apps.txt` and, for `enter_seconds`, also looks like a game: its exe is installed under one of the
`game_folders` (path fragments such as `/steamapps/common/`, `/epic games/`, `/xboxgames/`, `:/games/`), or its
window fills the monitor (fullscreen or borderless, not just maximised) while GPU load is at least the settings page's **GPU load** (`GpuLoad` in settings.inc; it used to be
`gpu_load` in `autoswitch.json`, and the builder moves it over).
Drawing frames alone isn't enough, because video calls, players and launchers draw frames too. `npwatch.exe`
reports the focused app's exe, fullscreen state and path to `res\focus.txt` for this check. About 2 seconds
after the game's process ends, the screen goes back to the page you were on. It also goes back if another
program has been drawing frames for `exit_seconds` while the game stays open (you've switched to something else). If you
swipe away from the gaming page during a game, it won't come back until that game ends. If a program that isn't a
game triggers it, add its exe name to `ignored-apps.txt` (one per line; Settings > Files > Ignored apps) and delete it from `known-games.txt` if it got added there. The list used to be `ignore` in `autoswitch.json`; the builder moves it over.
Programs with "install", "setup", "unins" or "redist" in their exe name (installers, uninstallers, runtime
setups) are never treated as games (`NOT_GAME` in `game.lua`). Set `"enabled": false` to turn the feature off. Run
`install-skin.ps1` after any change.

The top of the gaming page shows the game: Steam's banner and logo, the name, total playtime, the last two
weeks, the current session, and achievements: how many are unlocked, a progress bar, and the next one to
aim for (the locked achievement the most players have). `rainmeter/gameinfo.ps1` looks this up when a game is
detected, all from Steam's files on this PC (install folders, `userdata\*\config\localconfig.vdf`,
`userdata\*\config\librarycache\<appid>.json`, `appcache\librarycache`), with no account or API key. A game
that isn't in this PC's Steam library (a standalone install, say in `D:\Games`) gets its banner from the Steam
store instead: the store's public search finds it by name (exact matches only). Like a library game it gets the
banner with the game's logo on top; when the store has no logo, the header image (title included) is shown uncropped
over a dimmed copy of itself. Pictures are downloaded once into `%LOCALAPPDATA%\ResMon\art`. A product name that's
just the initials of the exe's description ("KSA") is replaced by the description ("Kitten Space Agency"). For a game
the store doesn't have (or to replace any game's art), put your own pictures in `game-art\` next to
`known-games.txt`, named after the exe: `ksa.jpg` (or `.png`, the banner, cropped to fill) and optionally
`ksa-logo.png` (drawn over the banner's lower left). They're used ahead of Steam's own art the next time the game starts. Its name comes from the exe's version info, or else the exe's file name. Steam
refreshes its achievement cache when a game starts and stops, so achievements earned during the current
session show up next time. Steam updates its playtime when you quit a game, so the total doesn't include the
session in progress. Games from outside Steam show their name and session time only.

While no game is running, and for games without Steam artwork, the banner shows original artwork: a neon grid,
a sunset and a game controller. It comes from `screens/idle-hero.html` (an SVG; edit it and rebuild; opened
in a browser it plays the animation). The controller is animated in a 3-second loop: it floats and tilts, its glow and light
bar pulse, the face buttons light in turn and the sticks circle. The builder renders the banner without the
controller (`idle_hero.png`) and the controller as 24 frames (`idle_pad.png`, cut to `IDLE_BOX`). The skin plays
them 8 times a second (`[idlePad]`, `[mIdleFrame]`). `game.lua` hides and pauses the controller while a game's
own banner shows. The page redraws 8 times a second either way, about 6–8 % of one CPU core (under 0.5 % of
the whole CPU).

At the bottom, a now-playing strip shows the current track's cover, title and artist, with previous,
play/pause and next buttons. It doesn't run the music page's PowerShell helper: the title comes from the
watcher, and the cover is the thumbnail it saves for "Recently played". So the cover appears about 5 seconds
into a track, and videos show a music-note placeholder. The strip is hidden while nothing is playing; a paused
track keeps it, so you can resume from there. To fit the strip, the framerate panel is shorter (smaller
number and history chart).

`autoswitch.log` (next to `known-games.txt`) records every switch with its reason, and what was drawing
frames at the time: check it when the screen switches when it shouldn't, or doesn't switch back.

Every game it detects is added to `known-games.txt`. A known game switches the page within about 2 seconds of
starting, whether or not it's focused: the watcher (`npwatch.exe`, see the music page) checks the running
processes for known games. It stays on the gaming page until the game closes or you swipe away, even while you
use another window. When a known game closes while the gaming page is showing, the screen goes back to the
previous page even if you opened the gaming page yourself. The list survives rebuilds; delete a line to forget a game (no rebuild needed: it's
read each time a page loads).

### Music page

`screens/music.html` shows what's playing in any app that appears in Windows' media controls (the volume
flyout): YouTube Music or YouTube in the browser, Spotify, and so on. It shows the album art, title, artist,
album and progress, with touch buttons for previous, play/pause and next. Below that are the output device and
volume with −, + and mute buttons, a spectrum visualiser, and the recently played tracks.

- **Placeholder cover:** while nothing is playing, or for a track without artwork, the cover shows original
  artwork: a record sliding out of its sleeve, with neon notes. It comes from `screens/idle-music.html` (an SVG,
  with the same top and bottom fades as real covers; edit it and rebuild), which the builder renders to
  `idle_art.png` at the cover's size.
- **Player panel:** the track title, artist, album, progress and controls sit in one panel that overlaps the
  cover's bottom. Covers (`nowplaying.ps1`) and the placeholder fade out to transparent from halfway down and are
  gone at 83.6 % of their height, where the panel starts (`top:1050px` in `music.html`; change both together).

- **Spectrum:** Rainmeter's built-in AudioLevel plugin analyses what the default output device plays (48 bands,
  60 Hz–12 kHz). Pages with a visualiser redraw at 30 fps, while everything else still updates once a second.
  Rainmeter uses about 0.4 % of CPU on this page.
- **Recently played:** Windows doesn't expose the player's queue, so this lists the tracks played before the
  current one, with cover thumbnails and how long ago. The watcher adds a music track once it has played for
  5 seconds, so skipped tracks don't count. The list is stored on this PC in `np-history\` (project folder; last
  30 tracks). Delete the folder to clear it.

`rainmeter/nowplaying.ps1` reads the media info. It runs only while the music page is showing (about 120 MB of
memory) and stops about 15 seconds after you swipe away. The buttons send media keys, so they control whichever
player Windows considers current. Browsers pass Windows only a small thumbnail (120 px for YouTube Music). So
the cover is looked up in Apple's public iTunes search (no account or key) and shown at 1000 px. This sends the
artist, title and album to Apple. With an album, the artist has to match; without one (a song played as a YouTube
video, say), the artist and the title both have to match exactly. Extras such as "(Official Video)",
"- Remastered 2009" or a leading "Artist - " are left out of the title first. Anything without a confident match
keeps the player's own thumbnail.

Next to "Now playing", the header names the player. For music in a browser, Windows only says "Chrome" (or
Edge, Firefox), so the site (YouTube Music, YouTube, Spotify, SoundCloud…) is read from the browser's window
titles and checked again every 5 seconds. Browsers show only the active tab's title, so if the music tab sits
behind another tab, the browser's name is shown instead.

When music starts playing, the screen switches to the music page by itself (`rainmeter/music.lua`, settings
under `"music"` in `autoswitch.json`). Music means something is playing for `enter_seconds` and it's music: the
player reports an album, it's a music app (Spotify, the YouTube Music app…), or a browser window shows YouTube
Music. So a YouTube video doesn't trigger it (`"music_only": false` counts anything). Browsers show Windows only
the visible tab's title, so a YouTube Music tab hidden behind another tab counts only for tracks with an album. Once nothing
has played for `exit_seconds` (default 30, so a short pause doesn't bounce the page), it goes back to the page
you were on. If the player is closed, it goes back after `closed_seconds` (default 3) instead. Games come first: it never switches while a game is detected or the gaming page is showing, and
after a game it returns to the music page if that's where you were. If you swipe away from the music page after
it switched by itself, it stays away until the music stops for 5 seconds (pausing and playing again brings it
back). Switches, and every time music starts or stops, are logged in `autoswitch.log` with the reason a switch
didn't happen.

Chrome gives Windows one media entry for all its tabs, so after closing YouTube Music it can fall back to a
paused video in another tab. The music page shows "Nothing playing" in that case, unless that video played while
the page was open.

It uses `rainmeter/npwatch.cs`, a small watcher (about 20 MB) that the builder compiles with the C# compiler that comes
with Windows. It writes the playback status to `res\npstatus.txt` once a second, runs while Rainmeter does,
and doesn't contact anything online.

New slot options this page uses:
- `data-lc="button" data-action="PlayPause|Next|Prev|VolUp|VolDown|Mute"`: an invisible touch area.
- `data-lines="1|2"` on a text slot: the text is clipped to the element's width, wrapping to that many lines
  and ending in "…".
- `data-lc="image" data-sensor="NP_ART"`: a picture the helper renders at exactly the slot's size.
- `data-lc="visualizer" data-bars="48" data-gap="6" data-reflect="0.2" data-on="#3DE0FF" data-gradient="#FF4FA3"
  data-off="#101A2C"`: spectrum bars with a gradient, dim tracks and a mirror below. Optional: `data-fmin`,
  `data-fmax` (Hz), `data-sensitivity` (dB range).
- `NP_H1_TITLE`…`NP_H6_TITLE`, `_ARTIST`, `_AGO` and `_ART` (image): the recently played rows.
- `<div data-group="np" data-show="playing">…</div>` around part of a design: its static art is rendered as a
  separate layer instead of into the background. With `data-show="playing"`, the whole group (art, text,
  images and buttons) shows only while something is playing or paused. The group's children keep their
  page coordinates.

### Weather

`screens/weather.html` uses `WX_*` slots (`WX_TEMP`, `WX_COND`, `WX_HIGH`, `WX_D1_DAY`…`WX_D5_LOW`, and
`data-lc="icon"` for `WX_ICON` / `WX_Dn_ICON`). Every 15 minutes `rainmeter/weather.ps1` fetches the
forecast from Open-Meteo for the location picked on the settings page (`WxCity`, `WxCityLat`, `WxCityLon` in
settings.inc; it starts as `weather.json`'s `name` / `latitude` / `longitude`). To offer another place, add it to
`locations` in `weather.json` (name, latitude, longitude) and rebuild. `weather.json` is your own and isn't in the
repository: the first build copies `weather.example.json` (London and 16 other cities) to make it.
**Automatic** finds where the PC is with Windows' location service (Settings > Privacy & security > Location must
allow desktop apps; it uses Wi-Fi, so it knows the suburb, unlike IP lookups, which put this PC in Christchurch).
The position is rounded to about 1 km and named by OpenStreetMap (Nominatim), asked only when the place changes;
the name is kept in `%LOCALAPPDATA%\ResMon\place.json`. If Windows can't say, the last place found is used, or
`weather.json`'s. The cache notes which place it's for
(`"loc"`), so a new location is fetched straight away rather than showing the old forecast. If Open-Meteo doesn't answer within 8 seconds, it uses
MET Norway instead; MET doesn't forecast rain chance here, so that shows `--` until Open-Meteo is back. Neither
needs an API key. The last forecast is kept in `wx-cache.json` (project folder), so it shows immediately after a
page swap, rebuild or reboot; a failed fetch is retried after 5 minutes. The icons are original line art in `wx-icons.js`.

- **Animated icons:** the sun's rays turn, clouds drift, rain, drizzle and snow fall from under the cloud,
  stars twinkle, fog lines slide and lightning flashes. Each icon is a 2-second loop of 16 frames (`WX_ICON_FRAME` in
  `wx-icons.js`). The builder renders one frame strip per icon and size (`wx_<size>_<icon>.png`); the skin
  steps through it 8 times a second (`[mWxFrame]`). Readings still update once a second. Rainmeter uses about 8 % of
  one CPU core on this page, against about 2.5 % on Home. To turn the animation off, set `"animate_icons": false`
  in `weather.json` and rebuild. A design opened in a browser animates its icons too.
- **Next 24 hours:** `WX_H1`…`WX_H8` (`_TIME`, `_ICON`, `_TEMP`, `_POP`) are the forecast every 3 hours from
  the current hour at that location (`HOURS` / `HSTEP` in `wx.lua`); times are the location's local time. The first column reads "Now". MET Norway gives no rain chance,
  so that line is blank on the fallback.
- **UV index:** `WX_UV` / `WX_UV_LABEL` (now) and `WX_UV_PEAK` / `WX_UV_PEAK_TIME` (highest in the next 24 h),
  coloured by WHO band: Low green, Moderate yellow, High orange, Very high red, Extreme violet. The dot on the
  0–11+ scale follows the current UV. On the MET fallback, UV is the clear-sky value, so it reads high on cloudy days.
- Two builder features came with this: `data-color-var="NAME"` on a text slot takes its colour from a skin
  variable, and `data-lc="marker"` (`data-sensor`, `data-max`, `data-range` in px, `data-fill`, `data-stroke`,
  `data-stroke-width`) is a dot drawn by the skin that slides right by `value / max × range` from where the
  element sits, so place it at the scale's zero.

Notes on the skin:
- Rainmeter isn't DPI-aware, so it works in the screen's scaled size and Windows stretches it to fill. Keep the
  Y70 at **100 %** scaling (Settings > System > Display): the skin is then built at the full 1100×3840 and is
  sharpest. At 150 % it's built at 733×2560 and comes out slightly soft. `install-skin.ps1` reads the size, so
  rebuild after changing the scaling. Signing out and back in after a change keeps older apps' coordinates right.
- Charts keep one sample per pixel (about 10 minutes of history) and start as a flat line at zero.

## Making a new design

Copy `screens/home.html`. Keep `<div id="stage" data-width="1100" data-height="3840">` and the
`<script src="../lc-live.js">`, list it in `pages.txt` and run `install-skin.ps1`. To check the layout first, open
the design in a browser: it shows with sample values. A few things work that L-Connect can't do:

- `data-sensor="HW:<label>"` binds any value HWiNFO exports, by its HWiNFO label (e.g. `HW:GPU Hot Spot Temperature`).
- `data-warn="85" data-warn-color="#FF3B3B"` switches colour above a threshold (text, bars, arcs, needles).
- `data-decimals="1"` sets the number of decimals on a text slot.
- `data-max="auto"` makes a chart scale to its own peak (good for network).
- Layout can use flexbox and any CSS, and there's no 1 MB frame limit. Fonts must be installed on this PC.

## Adding sensors

Sensors available now: CPU load, temperature and power; GPU load, temperature, hot spot, memory junction temperature,
power, clock and VRAM %; RAM; network; FPS. To add more (CPU clock, fans, pump, drives), enable *Report value in
Gadget* for them in HWiNFO. They then show up under `HW:` right away. To give one a short key, add its label to
`LABELS` in `rainmeter/sensors.py` and run `install-skin.ps1`.

## Notes

- HWiNFO must be running, with *Report value in Gadget* on for the sensors the pages use.
- If touches land on the wrong monitor, run Windows' *Calibrate the screen for pen or touch input* → *Setup*
  and tap the Y70 screen when it asks.
- HYTE Nexus isn't needed. If you install it later, its own screen content may compete with the skin.

## License

MIT (see [LICENSE](LICENSE)). ResMon is based on biltrex's [lconnect-screen-template](https://github.com/biltrex/lconnect-screen-template), also MIT; its notice is in LICENSE too. Built with the help of Claude (Anthropic). Not affiliated with or endorsed by HYTE.
