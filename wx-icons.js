/* wx-icons.js: weather icons (original line art, 64x64 viewBox) and the WMO weather-code mapping.
   Used by lc-live.js to preview data-lc="icon" slots and by rainmeter/build_skin.py to render icon sprites.
   Sprite order = WX_ICONS order; the Rainmeter skin picks a frame by index.
   Each icon is also animated: WX_ICON_FRAME(name, t) draws it at phase t (0..1, one seamless loop):
   sun rays turn, clouds drift, rain and snow fall from under the cloud, stars twinkle, lightning flashes. */
(function () {
  const SUN = '#FFC44D', MOON = '#C9D4FF', CLOUD = '#D5E0F0', CLOUD2 = '#8FA3BF', RAIN = '#3DE0FF', SNOW = '#FFFFFF', BOLT = '#FFB547';
  const TAU = Math.PI * 2;
  const sw = 'stroke-width="3.2" stroke-linecap="round" stroke-linejoin="round"';
  const f1 = v => (+v).toFixed(1), f2 = v => (+v).toFixed(2);
  const wave = (t, ph = 0) => Math.sin(TAU * (t + ph));
  const cloud = (dx, dy, s, c) =>
    `<path transform="translate(${f1(dx)} ${f1(dy)}) scale(${s})" d="M18 46h28a10 10 0 0 0 0-20a14 14 0 0 0-26.5-4.5A11 11 0 0 0 18 46z" fill="#0B1424" stroke="${c}" ${sw}/>`;
  // rot: rays turn by up to 45 degrees per loop (they have 8-fold symmetry, so the loop is seamless)
  const sun = (cx, cy, r, rays, rot = 0) => {
    let s = `<circle cx="${cx}" cy="${cy}" r="${r}" fill="none" stroke="${SUN}" ${sw}/>`;
    if (rays) for (let i = 0; i < 8; i++) {
      const a = i * Math.PI / 4 + rot, r1 = r + 5, r2 = r + 10;
      s += `<line x1="${f1(cx + Math.cos(a) * r1)}" y1="${f1(cy + Math.sin(a) * r1)}" x2="${f1(cx + Math.cos(a) * r2)}" y2="${f1(cy + Math.sin(a) * r2)}" stroke="${SUN}" ${sw}/>`;
    }
    return s;
  };
  const moon = (dx, dy, s) =>
    `<path transform="translate(${dx} ${dy}) scale(${s})" d="M40 12a20 20 0 1 0 14 30A16 16 0 0 1 40 12z" fill="none" stroke="${MOON}" ${sw}/>`;
  const star = (x, y, k) => {             // a small twinkling cross; k 0..1
    const r = 1.2 + 2.2 * k;
    return `<g stroke="${MOON}" stroke-width="2" stroke-linecap="round" opacity="${f2(0.35 + 0.65 * k)}">` +
      `<line x1="${f1(x - r)}" y1="${y}" x2="${f1(x + r)}" y2="${y}"/><line x1="${x}" y1="${f1(y - r)}" x2="${x}" y2="${f1(y + r)}"/></g>`;
  };
  // rain / drizzle / snow, drawn before the cloud so each drop appears from under it and fades out below
  const drops = (c, kind, t) => {
    let s = '';
    [24, 34, 44].forEach((x, i) => {
      const p = (t + i / 3 + (i % 2) * 0.17) % 1;
      const o = f2(Math.min(1, 2.2 * Math.sin(Math.PI * p)));
      if (kind === 'rain') {
        const y = 38 + p * 14, x0 = x + 2 - p * 5;
        s += `<line x1="${f1(x0)}" y1="${f1(y)}" x2="${f1(x0 - 4)}" y2="${f1(y + 11)}" stroke="${c}" ${sw} opacity="${o}"/>`;
      } else if (kind === 'drizzle') {
        const y = 40 + p * 16, x0 = x - p * 2;
        s += `<line x1="${f1(x0)}" y1="${f1(y)}" x2="${f1(x0 - 1.5)}" y2="${f1(y + 4)}" stroke="${c}" ${sw} opacity="${o}"/>`;
      } else {
        const y = 42 + p * 17, x0 = x - 2 + 2 * wave(p, i / 3);
        s += `<circle cx="${f1(x0)}" cy="${f1(y)}" r="2.6" fill="${c}" opacity="${o}"/>`;
      }
    });
    return s;
  };
  const W = (inner) => `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">${inner}</svg>`;
  const DRAW = {
    'clear-day':    t => sun(32, 32, 12, true, t * Math.PI / 4),
    'clear-night':  t => moon(-2, 2, 1) + star(52, 12, 0.5 + 0.5 * wave(t)) + star(57, 27, 0.5 + 0.5 * wave(t, 0.45)),
    'partly-day':   t => sun(23, 22, 9, true, t * Math.PI / 4) + cloud(6 + 1.5 * wave(t), 6, 0.86, CLOUD),
    'partly-night': t => moon(-8, -6, 0.75) + star(50, 9, 0.5 + 0.5 * wave(t)) + cloud(6 + 1.5 * wave(t), 6, 0.86, CLOUD),
    'cloudy':       t => cloud(2 * wave(t), -6, 0.78, CLOUD2) + cloud(6 - 1.5 * wave(t), 5, 0.86, CLOUD),
    'fog':          t => cloud(2 + wave(t), -6, 0.9, CLOUD2) + [46, 52, 58].map((y, i) => {
                      const dx = 3 * wave(t, i / 3);
                      return `<line x1="${f1(12 + i * 3 + dx)}" y1="${y}" x2="${f1(52 - i * 3 + dx)}" y2="${y}" stroke="${CLOUD}" ${sw}/>`; }).join(''),
    'drizzle':      t => drops(RAIN, 'drizzle', t) + cloud(2, -6, 0.9, CLOUD),
    'rain':         t => drops(RAIN, 'rain', t) + cloud(2, -6, 0.9, CLOUD),
    'snow':         t => drops(SNOW, 'snow', t) + cloud(2, -6, 0.9, CLOUD),
    // lightning: dim most of the time, a double flash (two frames apart) at the start of each loop
    'thunder':      t => cloud(2, -8, 0.9, CLOUD) +
                      `<path d="M34 38l-8 11h8l-5 10" fill="none" stroke="${BOLT}" ${sw} opacity="${(t < 0.03 || (t > 0.1 && t < 0.15)) ? 1 : 0.4}"/>`,
  };
  const frame = (name, t) => W(DRAW[name](((t % 1) + 1) % 1));
  const ICONS = {};
  Object.keys(DRAW).forEach(k => { ICONS[k] = frame(k, k === 'thunder' ? 0 : 0.1); });   // still image (lightning lit)
  const ORDER = Object.keys(ICONS);
  // WMO weather code (+ day/night) -> icon name
  function iconFor(code, isDay) {
    code = +code; const d = isDay === undefined || +isDay === 1;
    if (code <= 0) return d ? 'clear-day' : 'clear-night';
    if (code <= 2) return d ? 'partly-day' : 'partly-night';
    if (code === 3) return 'cloudy';
    if (code === 45 || code === 48) return 'fog';
    if (code >= 51 && code <= 57) return 'drizzle';
    if ((code >= 61 && code <= 67) || (code >= 80 && code <= 82)) return 'rain';
    if ((code >= 71 && code <= 77) || code === 85 || code === 86) return 'snow';
    if (code >= 95) return 'thunder';
    return 'cloudy';
  }
  window.WX_ICONS = ICONS; window.WX_ORDER = ORDER; window.WX_ICON_FOR = iconFor; window.WX_ICON_FRAME = frame;
})();
