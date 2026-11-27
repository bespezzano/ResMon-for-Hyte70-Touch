/* lc-live.js: draws a ResMon design (screens/*.html) from its data-lc slots: text, label, bar, slider, arc, chart,
   needle, ring, image, icon (see the README).

   rainmeter/build_skin.py opens each design with it in headless Chrome (?mode=geom ...) to capture the static art
   and every slot's position, size, font and colour. Opened directly in a browser, a design shows as a preview with
   its sample values (data-sample) and a live clock, scaled to fit the window.

   Page layout: put the design in <div id="stage" data-width="1100" data-height="3840">.

   Extras the L-Connect screen can't do:
     data-sensor="HW:<HWiNFO label>"     any value HWiNFO exports to the gadget registry
     data-decimals="1"                   override number formatting on text slots
     data-warn="85" data-warn-color="#F44"  switch colour at a threshold (text, bar, arc, needle) */
(function () {
  'use strict';
  const num = (v, d) => (v === undefined || v === '' || isNaN(+v) ? d : +v);
  const yes = v => v !== undefined && v !== 'false' && v !== '0';
  const rad = deg => (deg - 90) * Math.PI / 180;      // 0 deg = 12 o'clock, clockwise
  const MAX = { CPUTEMP: 110, HDDTEMP: 110, GPUTEMP: 100, CPUTEMP_F: 230, GPUTEMP_F: 230, UPSPEED: 100, DOWNSPEED: 100 };
  const DEC = { CPUCLOCK_G: 2, GPUCLOCK_G: 2, RAM_GB: 1, RAMTOTAL_GB: 1, RAMVALID_GB: 1, CPUVOLTAGE: 2, GPUVOLTAGE: 2 };
  const pad = n => String(n).padStart(2, '0');
  const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const DAYS_FULL = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const MONTHS_FULL = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];

  let data = null, scale = 1;       // data: no live values (previews show the samples)
  // ?mode=bg / ?mode=geom: used by rainmeter/build_skin.py to capture the static art and the slot geometry
  const MODE = new URLSearchParams(location.search).get('mode');
  // data-group="<name>" on a container: its static art is left out of the background and captured on its own
  // (?only=<name>&ox=&oy=: just that group, on a transparent page, shifted so its corner is at 0,0), so the
  // skin can show and hide the whole group
  const QS = new URLSearchParams(location.search), ONLY = QS.get('only');
  const OX = +(QS.get('ox') || 0), OY = +(QS.get('oy') || 0);
  const stage = document.getElementById('stage') || document.body;
  const SW = num(stage.dataset.width, stage.offsetWidth);
  let SH = num(stage.dataset.height, stage.offsetHeight);

  // ---------- values ----------
  function clock(el) {
    const n = new Date(), s = (el.dataset.sensor || '').toUpperCase(), sub = el.dataset.sub || '';
    if (s === 'TIME') return ({ 'h:m:s': `${pad(n.getHours())}:${pad(n.getMinutes())}:${pad(n.getSeconds())}`,
      'h:m': `${pad(n.getHours())}:${pad(n.getMinutes())}`, h_24: pad(n.getHours()), h_12: pad(n.getHours() % 12 || 12),
      m: pad(n.getMinutes()), s: pad(n.getSeconds()) })[sub || 'h:m:s'];
    if (s === 'APM') return n.getHours() < 12 ? 'AM' : 'PM';
    if (s === 'DATE') return ({ 'Y-M-D': `${n.getFullYear()}-${pad(n.getMonth() + 1)}-${pad(n.getDate())}`, Y: String(n.getFullYear()),
      M: pad(n.getMonth() + 1), D: pad(n.getDate()), D_num: String(n.getDate()), M_en: MONTHS[n.getMonth()],
      M_full: MONTHS_FULL[n.getMonth()] })[sub || 'Y-M-D'];
    if (s === 'DAY') return sub === 'Num' ? String(n.getDay()) : sub === 'Day_full' ? DAYS_FULL[n.getDay()] : DAYS[n.getDay()];
    return undefined;
  }
  function raw(el) {
    const s = el.dataset.sensor || '';
    if (!data) return undefined;
    if (s.startsWith('HW:')) return data.HW ? data.HW[s.slice(3)] : undefined;
    return data[s.toUpperCase()];
  }
  function frac(el, v) {
    const s = (el.dataset.sensor || '').toUpperCase();
    return Math.max(0, Math.min(1, v / num(el.dataset.max, MAX[s] || 100)));
  }
  function warnColor(el, v, base) {
    const w = el.dataset.warn;
    return w !== undefined && v !== undefined && v >= +w ? (el.dataset.warnColor || '#FF4D4D') : base;
  }

  // ---------- canvas per slot ----------
  function canvasFor(el, padY) {
    let c = el._lcCanvas;
    const w = el.offsetWidth, h = el.offsetHeight, k = scale * (window.devicePixelRatio || 1);
    if (!c) {
      if (getComputedStyle(el).position === 'static') el.style.position = 'absolute';
      c = document.createElement('canvas'); el.appendChild(c); el._lcCanvas = c;
    }
    const bw = Math.max(1, Math.round(w * k)), bh = Math.max(1, Math.round((h + 2 * padY) * k));
    if (c.width !== bw || c.height !== bh) { c.width = bw; c.height = bh; }
    c.style.cssText = `position:absolute;left:0;top:${-padY}px;width:${w}px;height:${h + 2 * padY}px;pointer-events:none`;
    const g = c.getContext('2d');
    g.setTransform(k, 0, 0, k, 0, padY * k); g.clearRect(-1, -padY - 1, w + 2, h + 2 * padY + 2);
    return [g, w, h];
  }
  function rrect(g, x, y, w, h, r) {
    r = Math.max(0, Math.min(r, w / 2, h / 2));
    g.beginPath(); g.moveTo(x + r, y); g.arcTo(x + w, y, x + w, y + h, r); g.arcTo(x + w, y + h, x, y + h, r);
    g.arcTo(x, y + h, x, y, r); g.arcTo(x, y, x + w, y, r); g.closePath();
  }

  // ---------- widgets (drawing ported from the template's lc-preview.js) ----------
  function bar(el, v, slider) {
    const d = el.dataset, kn = slider ? num(d.knob, el.offsetHeight * 2) : 0;
    const [g, w, h] = canvasFor(el, Math.max(0, (kn - el.offsetHeight) / 2 + 1)), p = frac(el, v);
    const fill = d.fill || (h > w ? 'btt' : 'ltr'), vertical = fill === 'btt' || fill === 'ttb';
    const len = vertical ? h : w, r = num(d.radius, 0), on = warnColor(el, v, d.on || '#fff'), off = d.off || 'transparent';
    const track = d.track || 'solid', lw = num(d.lineWidth, 2);
    const n = num(d.segments, 0), gap = num(d.gap, 0);
    if (track === 'solid' && n <= 1) { g.fillStyle = off; rrect(g, 0, 0, w, h, r); g.fill(); }
    if (track === 'outline') { g.strokeStyle = off; g.lineWidth = lw; rrect(g, lw / 2, lw / 2, w - lw, h - lw, r); g.stroke(); }
    const box = (a, b) => fill === 'ltr' ? [a, 0, b - a, h] : fill === 'rtl' ? [w - b, 0, b - a, h]
                        : fill === 'ttb' ? [0, a, w, b - a] : [0, h - b, w, b - a];
    let st = on;
    if (d.gradient && on === (d.on || '#fff')) {
      const gr = vertical ? g.createLinearGradient(0, fill === 'btt' ? h : 0, 0, fill === 'btt' ? 0 : h)
                          : g.createLinearGradient(fill === 'rtl' ? w : 0, 0, fill === 'rtl' ? 0 : w, 0);
      gr.addColorStop(0, on); gr.addColorStop(1, d.gradient); st = gr;
    }
    if (n > 1) {
      const blk = (len - (n - 1) * gap) / n, lit = Math.round(p * n);
      for (let i = 0; i < n; i++) {
        const a = i * (blk + gap);
        if (i >= lit && (track === 'none' || off === 'transparent')) continue;
        g.fillStyle = i < lit ? st : off; g.fillRect(...box(a, a + blk));
      }
    } else if (p > 0) { g.fillStyle = st; const b = box(0, Math.max(slider ? 0 : r * 2, p * len)); rrect(g, ...b, r); g.fill(); }
    if (slider) {
      const k = num(d.knob, h * 2), c = fill === 'rtl' ? w - p * w : p * w;
      g.fillStyle = d.knobColor || on; g.beginPath(); g.arc(Math.max(k / 2, Math.min(w - k / 2, c)), h / 2, k / 2, 0, 7); g.fill();
    }
  }

  function arc(el, v) {
    const [g, w] = canvasFor(el, 0), d = el.dataset, p = frac(el, v);
    const t = num(d.thickness, w * 0.1), R = (w - t) / 2, c = w / 2;
    const start = num(d.start, 0), sweep = num(d.sweep, 360), rev = yes(d.reverse), dir = rev ? -1 : 1;
    const a0 = rad(start), a1 = rad(start + dir * sweep * p), aEnd = rad(start + dir * sweep);
    g.lineWidth = t; g.lineCap = yes(d.round) ? 'round' : 'butt';
    if (d.track !== 'none' && d.off) { g.strokeStyle = d.off; g.beginPath(); g.arc(c, c, R, a0, aEnd, rev); g.stroke(); }
    if (d.border) { g.save(); g.lineWidth = num(d.border, 2); g.strokeStyle = d.off || '#888';
      for (const rr of [R - t / 2, R + t / 2]) { g.beginPath(); g.arc(c, c, Math.max(1, rr), 0, 7); g.stroke(); } g.restore(); }
    const on = warnColor(el, v, d.on || '#fff');
    let st = on;
    if (d.gradient && on === (d.on || '#fff') && g.createConicGradient) {
      // start the gradient a cap-width before the arc so a round start cap isn't painted with the end colour
      const cap = yes(d.round) ? t / 2 / R : 0, capF = cap / (2 * Math.PI), sf = Math.min(1 - capF, sweep / 360);
      const cg = g.createConicGradient((rev ? aEnd : a0) - cap, c, c);
      cg.addColorStop(capF, rev ? d.gradient : on); cg.addColorStop(capF + sf, rev ? on : d.gradient); st = cg;
    }
    g.strokeStyle = st;
    const blk = num(d.block, 0), gap = num(d.gap, 0);
    if (blk > 0) {
      const da = (blk + gap) / R, db = blk / R, tot = Math.abs(a1 - a0);
      for (let a = 0; a < tot - 1e-6; a += da) { const s = a0 + dir * a; g.beginPath(); g.arc(c, c, R, s, s + dir * Math.min(db, tot - a), rev); g.stroke(); }
    } else if (p > 0.001) { g.beginPath(); g.arc(c, c, R, a0, a1, rev); g.stroke(); }
  }

  function chart(el, v) {
    const [g, w, h] = canvasFor(el, 0), d = el.dataset;
    const max = num(d.max, MAX[(d.sensor || '').toUpperCase()] || 100), step = num(d.step, 8), n = Math.max(2, Math.floor(w / step) + 1);
    const hist = el._lcHist || (el._lcHist = []);
    if (v !== undefined && el._lcTick !== tick) { hist.push(v); el._lcTick = tick; }
    while (hist.length > n) hist.shift();
    if (num(d.frameWidth, 0) > 0) { g.strokeStyle = d.frame || d.color; g.lineWidth = num(d.frameWidth, 1); g.strokeRect(0.5, 0.5, w - 1, h - 1); }
    if (hist.length < 2) return;
    const top = d.max === 'auto' ? Math.max(1, ...hist) * 1.15 : max;
    const x0 = d.anchor === 'left' ? 0 : w - (hist.length - 1) * step;
    const pts = hist.map((q, i) => [x0 + i * step, h - Math.max(0, Math.min(top, q)) / top * h]);
    if (d.fillColor) { g.fillStyle = d.fillColor; g.beginPath(); g.moveTo(pts[0][0], h); pts.forEach(q => g.lineTo(q[0], q[1])); g.lineTo(pts[pts.length - 1][0], h); g.fill(); }
    g.strokeStyle = d.color || '#fff'; g.lineWidth = num(d.lineWidth, 2); g.lineJoin = 'round';
    g.beginPath(); pts.forEach((q, i) => i ? g.lineTo(q[0], q[1]) : g.moveTo(q[0], q[1])); g.stroke();
  }

  function needle(el, v) {
    const [g, w, h] = canvasFor(el, 0), d = el.dataset, c = [w / 2, h / 2], time = (d.sensor || '').toUpperCase() === 'TIME';
    let p;
    if (time) { const n = new Date(), s = n.getSeconds() + n.getMilliseconds() / 1000;
      p = { h_12: (n.getHours() % 12 + n.getMinutes() / 60) / 12, h_24: n.getHours() / 24, m: (n.getMinutes() + s / 60) / 60, s: Math.floor(s) / 60 }[d.sub] ?? 0; }
    else p = frac(el, v ?? 0);
    const ang = rad(num(d.start, time ? 0 : -135) + p * num(d.sweep, time ? 360 : 270));
    const L = num(d.length, Math.min(w, h) * 0.42), tail = num(d.tail, L * 0.18), wd = num(d.width, Math.max(2, L * 0.06));
    g.strokeStyle = warnColor(el, v, d.color || '#f44'); g.lineWidth = wd; g.lineCap = 'round';
    g.beginPath(); g.moveTo(c[0] - Math.cos(ang) * tail, c[1] - Math.sin(ang) * tail); g.lineTo(c[0] + Math.cos(ang) * L, c[1] + Math.sin(ang) * L); g.stroke();
    if (d.cap !== 'none') { g.fillStyle = d.cap || '#fff'; g.beginPath(); g.arc(c[0], c[1], Math.max(3, wd), 0, 7); g.fill(); }
  }

  function ring(el, v) {
    const [g, w] = canvasFor(el, 0), d = el.dataset, p = frac(el, v), t = w * 0.12, R = (w - t) / 2 - 2, c = w / 2;
    g.lineWidth = t; g.strokeStyle = d.bg || '#00454D'; g.beginPath(); g.arc(c, c, R, 0, 7); g.stroke();
    const gr = g.createLinearGradient(0, w, w, 0); gr.addColorStop(0, d.color2 || '#00FFEE'); gr.addColorStop(1, d.color1 || '#2A00FF');
    g.strokeStyle = gr; g.beginPath(); g.arc(c, c, R, rad(0), rad(360 * p)); g.stroke();
    g.fillStyle = d.textColor || '#fff'; g.textAlign = 'center'; g.font = `600 ${w * 0.26}px ${d.font || 'Bahnschrift'}, sans-serif`;
    g.fillText(String(Math.round(v)), c, c + w * 0.09);
  }

  function text(el) {
    const s = (el.dataset.sensor || '').toUpperCase();
    let out = clock(el);
    if (out === undefined) {
      const v = raw(el);
      if (v === undefined || v === null) return;
      if (typeof v === 'string') out = v;
      else out = v.toFixed(num(el.dataset.decimals, DEC[s] ?? 0));
      if (el.dataset.warn !== undefined) {
        if (el._lcColor === undefined) el._lcColor = el.style.color;
        el.style.color = v >= +el.dataset.warn ? (el.dataset.warnColor || '#FF4D4D') : el._lcColor;
      }
    }
    if (el.textContent !== out) el.textContent = out;
  }

  function gradientText(el) {
    const c = getComputedStyle(el).color, dir = num(el.dataset.gradientDir, 1);
    el.style.backgroundImage = `linear-gradient(${{ 1: '90deg', 2: '180deg', 3: '135deg' }[dir] || '90deg'}, ${c}, ${el.dataset.gradient})`;
    el.style.webkitBackgroundClip = 'text'; el.style.backgroundClip = 'text'; el.style.webkitTextFillColor = 'transparent';
  }

  // visualizer: data-bars bars (data-gap px apart) rising from a baseline, gradient data-on -> data-gradient,
  // dim data-off tracks behind them, and a faint mirror below (data-reflect = its height as a fraction of the
  // element). The Rainmeter skin drives the bars from the sound output; here they show a sample shape.
  function visualizer(el) {
    const d = el.dataset, [g, w, h] = canvasFor(el, 0);
    const n = num(d.bars, 40), gap = num(d.gap, 6), rf = num(d.reflect, 0.2), bw = (w - (n - 1) * gap) / n;
    const base = h / (1 + rf), on = d.on || '#3DE0FF', grad = d.gradient || on, off = d.off || 'transparent';
    const gr = g.createLinearGradient(0, base, 0, 0); gr.addColorStop(0, on); gr.addColorStop(1, grad);
    for (let i = 0; i < n; i++) {
      const x = i * (bw + gap);
      g.fillStyle = off; g.fillRect(x, 0, bw, base);
      if (MODE) continue;
      const t = i / (n - 1), v = Math.max(0.06, (0.75 - 0.5 * t) * (0.55 + 0.45 * Math.sin(i * 1.7) ** 2));
      g.fillStyle = gr; g.fillRect(x, base - v * base, bw, v * base);
      g.globalAlpha = 0.22; g.fillRect(x, base + 4, bw, v * (h - base - 4)); g.globalAlpha = 1;
    }
  }

  // ---------- loop ----------
  let tick = 0;
  const DRAW = { bar: (e, v) => bar(e, v, false), slider: (e, v) => bar(e, v, true), arc, chart, needle, ring,
                 visualizer: e => visualizer(e) };
  function icon(el) {
    if (el._lcIcon || !window.WX_ICONS) return;
    el._lcIcon = window.WX_ICON_FOR(num(el.dataset.sample, 0), el.dataset.day ?? 1);
    iconFrame(el, 0.1);
  }
  function iconFrame(el, t) {
    el.innerHTML = window.WX_ICON_FRAME ? window.WX_ICON_FRAME(el._lcIcon, t) : window.WX_ICONS[el._lcIcon];
    const svg = el.firstElementChild; svg.style.width = '100%'; svg.style.height = '100%';
  }
  // animated weather icons (same 2 s loop, 16 frames, as the Rainmeter skin)
  if (!MODE && window.WX_ICON_FRAME) {
    let fr = 0;
    setInterval(() => { fr = (fr + 1) % 16;
      document.querySelectorAll('[data-lc="icon"]').forEach(el => { if (el._lcIcon) iconFrame(el, fr / 16); }); }, 125);
  }
  function render() {
    document.querySelectorAll('[data-lc]').forEach(el => {
      const kind = el.dataset.lc;
      if (kind === 'icon') return MODE ? undefined : icon(el);
      if (kind === 'text') return text(el);
      const f = DRAW[kind]; if (!f) return;
      let v = raw(el);
      if (MODE) v = kind === 'chart' ? undefined : 0;
      else if (v === undefined && kind !== 'needle') v = el._lcLast ?? (data ? 0 : num(el.dataset.sample, 0));
      el._lcLast = v;
      f(el, v);
    });
  }
  function fit() {
    scale = MODE ? num(new URLSearchParams(location.search).get('scale') ?? undefined, 1) : Math.min(window.innerWidth / SW, window.innerHeight / SH);
    stage.style.transformOrigin = '0 0';
    stage.style.transform = `scale(${scale})`;
    stage.style.left = MODE ? `${-OX * scale}px` : `${(window.innerWidth - SW * scale) / 2}px`;
    if (MODE) stage.style.top = `${-OY * scale}px`;
    document.querySelectorAll('[data-lc]').forEach(el => { if (el._lcCanvas) el._lcCanvas.width = 0; });
    render();
  }
  // &theme=light (build_skin.py, settings: DarkTheme = 0): the light theme, made from the dark design by flipping
  // every colour's lightness (HSL: L -> 1 - L; hue and saturation stay), so dark panels turn light, white text turns
  // dark and the accents get deeper. Pictures are left alone. build_skin.py flips the skin's own colours the same way.
  function flipRGB(r, g, b) {
    r /= 255; g /= 255; b /= 255;
    const mx = Math.max(r, g, b), mn = Math.min(r, g, b), l = (mx + mn) / 2;
    let h = 0, s = 0;
    if (mx !== mn) {
      const d = mx - mn; s = l > 0.5 ? d / (2 - mx - mn) : d / (mx + mn);
      h = (mx === r ? (g - b) / d + (g < b ? 6 : 0) : mx === g ? (b - r) / d + 2 : (r - g) / d + 4) / 6;
    }
    const L = 1 - l;
    if (s === 0) return [L, L, L].map(v => Math.round(v * 255));
    const q = L < 0.5 ? L * (1 + s) : L + s - L * s, p = 2 * L - q;
    const hue = t => { t = (t + 1) % 1; return t < 1 / 6 ? p + (q - p) * 6 * t : t < 0.5 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p; };
    return [hue(h + 1 / 3), hue(h), hue(h - 1 / 3)].map(v => Math.round(v * 255));
  }
  const flipCss = v => v.replace(/rgba?\(([^)]+)\)/g, (m, a) => {
    const n = a.split(/[\s,\/]+/).filter(Boolean).map(parseFloat), [r, g, b] = flipRGB(n[0], n[1], n[2]);
    return n.length > 3 ? `rgba(${r}, ${g}, ${b}, ${n[3]})` : `rgb(${r}, ${g}, ${b})`;
  });
  const flipAny = v => {
    if (!v.startsWith('#')) return flipCss(v);
    let h = v.slice(1); if (h.length <= 4) h = [...h].map(c => c + c).join('');
    const [r, g, b] = flipRGB(parseInt(h.slice(0, 2), 16), parseInt(h.slice(2, 4), 16), parseInt(h.slice(4, 6), 16));
    return '#' + [r, g, b].map(x => x.toString(16).padStart(2, '0')).join('') + h.slice(6);
  };
  if (QS.get('theme') === 'light') {
    const PROPS = ['color', 'background-color', 'background-image', 'border-top-color', 'border-right-color',
                   'border-bottom-color', 'border-left-color', 'box-shadow', 'text-shadow', 'outline-color', 'fill',
                   'stroke', 'stop-color', 'flood-color', '-webkit-text-fill-color', 'text-decoration-color'];
    // read everything first: a parent's new colour would otherwise be inherited, and flipped a second time
    const todo = [], rules = [];
    [document.documentElement, document.body, ...document.body.querySelectorAll('*')].forEach((el, i) => {
      const cs = getComputedStyle(el);
      todo.push([el, PROPS.map(p => [p, cs.getPropertyValue(p)])]);
      for (const ps of ['::before', '::after']) {
        const pc = getComputedStyle(el, ps);
        if (pc.content === 'none' || pc.content === 'normal') continue;
        el.classList.add('lc-th' + i);
        rules.push(`.lc-th${i}${ps}{` + PROPS.map(p => { const v = pc.getPropertyValue(p); return /rgb/.test(v) ? `${p}:${flipCss(v)} !important;` : ''; }).join('') + '}');
      }
    });
    todo.forEach(([el, vals]) => vals.forEach(([p, v]) => { if (/rgb/.test(v)) el.style.setProperty(p, flipCss(v), 'important'); }));
    const st = document.createElement('style'); st.textContent = rules.join('\n'); document.head.appendChild(st);
    // the meters' colours (tracks drawn into the art at 0)
    document.querySelectorAll('[data-lc]').forEach(el => {
      for (const k of ['on', 'off', 'gradient', 'color', 'fillColor', 'warnColor', 'fill', 'stroke']) if (el.dataset[k]) el.dataset[k] = flipAny(el.dataset[k]);
    });
  }
  // &tall=<px> (build_skin.py, for screens taller in proportion than the design, such as the Y70 Touch Infinite):
  // the page is made that tall and the extra height is shared equally by the gaps between panels and the space
  // under the last panel (above the page dots). Everything moves with the panel it sits on (an element belongs to
  // the panel whose area it starts in; the line between two panels is the middle of their gap). Whatever is above
  // the first panel's gap stays put: headers, the music cover, the first panel itself.
  const TALL = num(QS.get('tall'), 0);
  if (TALL > SH) {
    const panels = [...stage.querySelectorAll('.panel')].map(p => [p.offsetTop, p.offsetTop + p.offsetHeight]).sort((a, b) => a[0] - b[0]);
    const bounds = panels.slice(1).map((p, i) => (panels[i][1] + p[0]) / 2);
    const step = (TALL - SH) / (bounds.length + 1);
    const shift = y => Math.round(bounds.filter(b => y >= b).length * step);
    const els = [...stage.querySelectorAll('*')].filter(el => el.offsetParent === stage && getComputedStyle(el).position === 'absolute');
    const tops = els.map(el => parseFloat(getComputedStyle(el).top));
    els.forEach((el, i) => { if (!isNaN(tops[i]) && shift(tops[i])) el.style.top = `${tops[i] + shift(tops[i])}px`; });
    SH = TALL; stage.dataset.height = TALL; stage.style.height = `${TALL}px`;
  }
  document.querySelectorAll('[data-lc="text"][data-gradient], [data-lc="label"][data-gradient]').forEach(gradientText);
  document.querySelectorAll('[data-lc]').forEach(el => { if (!['text', 'label', 'image'].includes(el.dataset.lc)) el.innerHTML = ''; });
  // ---------- export for the Rainmeter skin builder ----------
  function anchorOf(el) {
    if (el.dataset.align) return el.dataset.align;
    const p = el.parentElement, cs = getComputedStyle(p);
    const sibs = [...p.childNodes].filter(n => n.nodeType === 1 || n.textContent.trim());
    if (cs.justifyContent === 'center' && sibs.length === 1) return 'center';
    if (sibs[0] === el && cs.justifyContent !== 'center') return 'left';
    return 'right';
  }
  function box(r) {
    const o = stage.getBoundingClientRect();
    return { x: (r.left - o.left) / scale, y: (r.top - o.top) / scale, w: r.width / scale, h: r.height / scale };
  }
  function textRun(el, anchor, chained) {
    const tn = [...el.childNodes].find(n => n.nodeType === 3 && n.textContent.trim());
    if (!tn) return null;
    const t = tn.textContent, a = t.length - t.trimStart().length, b = t.trimEnd().length;
    const rg = document.createRange(); rg.setStart(tn, a); rg.setEnd(tn, b);
    const cs = getComputedStyle(el), d = el.dataset;
    return Object.assign(box(rg.getBoundingClientRect()), {
      text: el.innerText.trim(), live: d.lc === 'text', sensor: d.sensor, sub: d.sub, decimals: d.decimals,
      warn: d.warn, warnColor: d.warnColor, colorVar: d.colorVar, anchor, chained,
      // data-lines: the text is clipped to the element's width (and wraps to that many lines, ending in "…")
      lines: d.lines ? +d.lines : undefined, clipW: d.lines ? box(el.getBoundingClientRect()).w : undefined,
      lineH: d.lines ? parseFloat(cs.lineHeight) || parseFloat(cs.fontSize) * 1.2 : undefined,
      font: cs.fontFamily.split(',')[0].replace(/["']/g, '').trim(), size: parseFloat(cs.fontSize),
      weight: +cs.fontWeight, italic: cs.fontStyle === 'italic', color: cs.color, group: groupOf(el) });
  }
  function groupOf(el) { const g = el.closest('[data-group]'); return g ? g.dataset.group : undefined; }
  // each group's area: everything inside it, plus 40 px for shadows
  function groupBoxes() {
    return [...document.querySelectorAll('[data-group]')].map(g => {
      let x0 = Infinity, y0 = Infinity, x1 = -Infinity, y1 = -Infinity;
      g.querySelectorAll('*').forEach(e => {
        const b = box(e.getBoundingClientRect());
        if (b.w <= 0 || b.h <= 0) return;
        x0 = Math.min(x0, b.x); y0 = Math.min(y0, b.y); x1 = Math.max(x1, b.x + b.w); y1 = Math.max(y1, b.y + b.h);
      });
      x0 = Math.max(0, x0 - 40); y0 = Math.max(0, y0 - 40); x1 = Math.min(SW, x1 + 40); y1 = Math.min(SH, y1 + 40);
      return { name: g.dataset.group, show: g.dataset.show, x: x0, y: y0, w: x1 - x0, h: y1 - y0 };
    });
  }
  function exportGeometry() {
    const runs = [], hide = new Set();
    document.querySelectorAll('[data-lc="text"]').forEach(el => {
      if (hide.has(el)) return;
      const anchor = anchorOf(el), r = textRun(el, anchor, false);
      if (r) runs.push(r); hide.add(el);
      // units that follow a growing value on the same line move with it (only inside a line container,
      // never for absolutely positioned slots, whose neighbours are independent elements)
      if (anchor !== 'left' || el.parentElement === stage || getComputedStyle(el).position === 'absolute') return;
      for (let n = el.nextElementSibling; n; n = n.nextElementSibling) {
        if (getComputedStyle(n).position === 'absolute') break;
        const f = textRun(n, 'left', true); if (f) runs.push(f); hide.add(n);
      }
    });
    hide.forEach(el => { el.style.visibility = 'hidden'; });
    const meters = [...document.querySelectorAll('[data-lc="arc"],[data-lc="bar"],[data-lc="slider"],[data-lc="chart"],[data-lc="icon"],[data-lc="image"][data-sensor],[data-lc="button"],[data-lc="visualizer"],[data-lc="marker"],[data-lc="toggle"]')]
      .map(el => Object.assign(box(el.getBoundingClientRect()), { kind: el.dataset.lc, d: Object.assign({}, el.dataset), group: groupOf(el) }));
    const s = document.createElement('script'); s.type = 'application/json'; s.id = 'lc-geom';
    s.textContent = JSON.stringify({ width: SW, height: SH, runs, meters, groups: GROUPS }); document.body.appendChild(s);
  }
  let GROUPS = [];
  if (MODE) {
    fit(); GROUPS = groupBoxes();
    if (ONLY) {
      document.documentElement.style.background = document.body.style.background = 'transparent';
      stage.style.background = 'none'; stage.style.visibility = 'hidden';
    }
    // &layer=bg|panels|art: the page background (the stage's fill), the panels' fill, and everything else, each
    // as its own transparent image, so the skin can fade the first two (settings: see-through) without a rebuild
    const LAYER = new URLSearchParams(location.search).get('layer');
    if (!ONLY && LAYER) {
      // the page's own base colour (html/body) also fills the bg layer's edges, where the scaled stage falls a
      // fraction of a pixel short of the window
      const base = getComputedStyle(document.body).backgroundColor;
      document.documentElement.style.background = document.body.style.background = 'transparent';
      if (LAYER === 'bg') document.documentElement.style.background = base;
      const split = (el, cls) => {
        const cs = getComputedStyle(el), f = document.createElement('div');
        f.className = cls;
        f.style.cssText = 'position:absolute; left:0; top:0; right:0; bottom:0; border-radius:inherit; pointer-events:none';
        f.style.backgroundImage = cs.backgroundImage;
        // panels are drawn slightly translucent (e.g. #0C1424E6) over the dark page: give their layer the page's base
        // colour underneath, so it's fully solid (looks the same) and the Panels setting's 100 % really is solid
        f.style.backgroundColor = cls === 'lc-fill-panel' ? base : cs.backgroundColor;
        el.insertBefore(f, el.firstChild); el.style.background = 'none';
      };
      split(stage, 'lc-fill-bg');
      // a panel inside a data-group stays in its group's picture, so it hides with the group
      document.querySelectorAll('.panel').forEach(p => { if (!p.closest('[data-group]')) split(p, 'lc-fill-panel'); });
      if (LAYER === 'art') document.querySelectorAll('.lc-fill-bg, .lc-fill-panel').forEach(f => { f.style.display = 'none'; });
      else {
        stage.style.visibility = 'hidden';
        document.querySelectorAll(LAYER === 'bg' ? '.lc-fill-bg' : '.lc-fill-panel').forEach(f => { f.style.visibility = 'visible'; });
      }
    }
    // settings switches are drawn by the skin
    document.querySelectorAll('[data-lc="toggle"]').forEach(t => { t.style.visibility = 'hidden'; });
    // markers move with a value, so the skin draws them; keep them out of the background image
    document.querySelectorAll('[data-lc="marker"]').forEach(m => { m.style.visibility = 'hidden'; });
    document.querySelectorAll('[data-group]').forEach(g => { g.style.visibility = g.dataset.group === ONLY ? 'visible' : 'hidden'; });
    exportGeometry();
    return;
  }

  // preview in a browser
  window.addEventListener('resize', fit);
  fit();
  setInterval(() => document.querySelectorAll('[data-lc="needle"][data-sensor="TIME"], [data-lc="text"][data-sensor="TIME"]').forEach(el => el.dataset.lc === 'text' ? text(el) : needle(el)), 250);
})();
