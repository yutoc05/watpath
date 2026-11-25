// Shared drawing for the banners. The campus comes from build/readme/data.js (written by
// tools/demo/make_readme_media.py) as meters east and south of its origin.
window.WP = (() => {
  const NS = 'http://www.w3.org/2000/svg';
  const data = window.WATPATH;

  /** Scales meters into a box, keeping north up: returns a function from [x, y] to pixels. */
  function fit(points, box, pad = 0) {
    const xs = points.map(p => p[0]);
    const ys = points.map(p => p[1]);
    const [minX, maxX, minY, maxY] = [Math.min(...xs), Math.max(...xs), Math.min(...ys), Math.max(...ys)];
    const s = Math.min((box.width - 2 * pad) / (maxX - minX), (box.height - 2 * pad) / (maxY - minY));
    const ox = box.x + (box.width - s * (maxX - minX)) / 2 - s * minX;
    const oy = box.y + (box.height - s * (maxY - minY)) / 2 - s * minY;
    const f = ([x, y]) => [ox + s * x, oy + s * y];
    f.scale = s;
    return f;
  }

  /** Every point on the campus, for fitting the whole of it. */
  const allPoints = () => data.buildings.flatMap(b => b.rings.flat());

  const d = (points, f, close = false) =>
    points.map((p, i) => `${i ? 'L' : 'M'}${f(p).map(v => v.toFixed(2)).join(' ')}`).join('') + (close ? 'Z' : '');

  function el(name, attrs = {}, parent) {
    const node = document.createElementNS(NS, name);
    for (const [k, v] of Object.entries(attrs)) node.setAttribute(k, v);
    if (parent) parent.appendChild(node);
    return node;
  }

  /** The Path Map: footprints, corridors, bridges and tunnels, as the app draws them. */
  function drawCampus(svg, f, options = {}) {
    const { corridor = 1, link = 1.7, glow = true, doors = false, buildingFill = 'var(--building)' } = options;
    const g = el('g', {}, svg);
    const footprints = el('path', {
      d: data.buildings.map(b => b.rings.map(r => d(r, f, true)).join('') + b.holes.map(h => d(h, f, true)).join('')).join(''),
      fill: buildingFill, 'fill-rule': 'evenodd', stroke: 'var(--building-edge)', 'stroke-width': 0.6,
    }, g);
    const lines = el('g', { fill: 'none', 'stroke-linecap': 'round', 'stroke-linejoin': 'round' }, g);
    el('path', { d: data.corridors.map(c => d(c, f)).join(''), stroke: '#fff', 'stroke-width': corridor, opacity: .92 }, lines);
    for (const kind of ['bridge', 'tunnel']) {
      const path = data.connections.filter(c => c.kind === kind).flatMap(c => c.paths).map(p => d(p, f)).join('');
      if (glow) el('path', { d: path, stroke: `var(--${kind})`, 'stroke-width': link * 4, opacity: .22, filter: 'url(#soft)' }, lines);
      el('path', { d: path, stroke: `var(--${kind})`, 'stroke-width': link }, lines);
    }
    if (doors) {
      const dots = el('g', { fill: 'var(--honey)', opacity: .55 }, g);
      for (const p of data.doors) {
        const [x, y] = f(p);
        el('circle', { cx: x, cy: y, r: doors }, dots);
      }
    }
    return { g, footprints };
  }

  /** A blur filter for glows, added once per SVG. */
  function defs(svg) {
    const defs = el('defs', {}, svg);
    const soft = el('filter', { id: 'soft', x: '-50%', y: '-50%', width: '200%', height: '200%' }, defs);
    el('feGaussianBlur', { stdDeviation: 2.4 }, soft);
    return defs;
  }

  const fonts = () => Promise.all([
    document.fonts.load('600 38px Inter'), document.fonts.load('400 14px Inter'),
    document.fonts.load('500 11px "Geist Mono"'), document.fonts.load('700 15px Quicksand'),
  ]).then(() => document.fonts.ready);

  /** Resolves once fonts and every image on the page have loaded. */
  const ready = () => fonts().then(() => Promise.all([...document.images].map(img => img.decode().catch(() => {}))));

  return { data, fit, allPoints, d, el, drawCampus, defs, ready };
})();
