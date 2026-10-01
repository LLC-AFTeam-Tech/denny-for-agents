(() => {
  // native/macos/DennyNotchHost/Sources/DennyNotchHostApp/Resources/DennyActivities/source/living-eyes.js
  var clamp = (x, a = -1, b = 1) => Math.min(b, Math.max(a, Number.isFinite(x) ? x : 0));
  function drawLivingEye(ctx, { x, y, width = 148, height = 207, gazeX = 0, gazeY = 0, blink = 0, tilt = 0, side = 1 }) {
    const gx = clamp(gazeX), gy = clamp(gazeY), opening = 1 - clamp(blink, 0, 1), close = 1 - opening;
    ctx.save();
    ctx.translate(x + gx * width * 0.048, y + gy * height * 0.025);
    ctx.rotate(tilt + (-gx * 12 + side * Math.abs(gx) * 2) * Math.PI / 180);
    ctx.translate(-width / 2, -height / 2);
    const w = width, h = height;
    ctx.save();
    ctx.beginPath();
    ctx.ellipse(w / 2, h / 2, w / 2, h / 2, 0, 0, Math.PI * 2);
    ctx.clip();
    const upper = h * close * 0.59, lower = h * (1 - close * 0.41);
    ctx.beginPath();
    ctx.moveTo(-w, upper - h * 0.1 * close);
    ctx.quadraticCurveTo(w / 2, upper + h * 0.2 * close, 2 * w, upper - h * 0.1 * close);
    ctx.lineTo(2 * w, lower + h * 0.08 * close);
    ctx.quadraticCurveTo(w / 2, lower - h * 0.16 * close, -w, lower + h * 0.08 * close);
    ctx.closePath();
    ctx.clip();
    const white = ctx.createRadialGradient(w * 0.28, h * 0.22, 0, w * 0.28, h * 0.22, h * 0.9);
    [[0, "#fff"], [0.4, "#fbfbfc"], [0.75, "#d4d6de"], [1, "#7d828f"]].forEach(([s, c]) => white.addColorStop(s, c));
    ctx.fillStyle = white;
    ctx.fillRect(0, 0, w, h);
    const depth = Math.sqrt(Math.max(0.2, 1 - (gx * 0.7) ** 2 - (gy * 0.63) ** 2));
    const pw = w * 0.48 * (0.78 + depth * 0.22), ph = h * 0.51 * (0.87 + depth * 0.13);
    const px = w * (0.5 + gx * 0.235), py = h * (0.56 + gy * 0.2);
    ctx.beginPath();
    ctx.ellipse(px, py, pw / 2, ph / 2, 0, 0, Math.PI * 2);
    const pupil = ctx.createLinearGradient(px, py - ph / 2, px, py + ph / 2);
    pupil.addColorStop(0, "#111217");
    pupil.addColorStop(0.5, "#000");
    pupil.addColorStop(1, "#06090b");
    ctx.fillStyle = pupil;
    ctx.fill();
    ctx.clip();
    ctx.fillStyle = "rgba(255,255,255,.98)";
    ctx.beginPath();
    ctx.ellipse(px + pw * 0.125 - gx * w * 0.025, py - ph * 0.265, pw * 0.145, ph * 0.125, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.fillStyle = "rgba(255,255,255,.065)";
    ctx.beginPath();
    ctx.ellipse(px - pw * 0.015, py + ph * 0.34, pw * 0.285, ph * 0.11, 0, 0, Math.PI * 2);
    ctx.fill();
    ctx.restore();
    if (opening < 0.12) {
      ctx.globalAlpha *= 1 - opening / 0.12;
      ctx.strokeStyle = "#b8b8b8";
      ctx.lineWidth = w * 0.055;
      ctx.lineCap = "round";
      ctx.beginPath();
      ctx.moveTo(w * 0.14, h * 0.54);
      ctx.quadraticCurveTo(w * 0.5, h * 0.66, w * 0.86, h * 0.54);
      ctx.stroke();
    }
    ctx.restore();
  }
  function drawSceneEyes(ctx, { nod = 0, gazeX = 0, gazeY = 0, blink = 0, level = false }) {
    drawLivingEye(ctx, { x: 581, y: (level ? 370 : 348.5) + nod, width: level ? 138 : 148, height: 207, gazeX, gazeY, blink, tilt: level ? 0 : 0.18, side: -1 });
    drawLivingEye(ctx, { x: 882.5, y: (level ? 370 : 409) + nod, width: level ? 152 : 185, height: level ? 207 : 214, gazeX, gazeY, blink, tilt: level ? 0 : 0.3, side: 1 });
  }

  // native/macos/DennyNotchHost/Sources/DennyNotchHostApp/Resources/DennyActivities/source/calendar-scene.js
  var load = (name) => new Promise((resolve, reject) => {
    const i = new Image();
    i.onload = () => resolve(i);
    i.onerror = () => reject(Error(name));
    i.src = new URL(name, window.location.href);
  });
  var clamp2 = (x) => Math.max(0, Math.min(1, x));
  var smooth = (a, b, x) => {
    const t = clamp2((x - a) / (b - a));
    return t * t * (3 - 2 * t);
  };
  async function createCalendarScene(canvas2) {
    const [face, base, hand] = await Promise.all(["calendar-keyframe.png", "calendar-base.png", "calendar-hand.png"].map(load));
    const ctx = canvas2.getContext("2d", { alpha: false });
    function feature(rect, x, y, sx = 1, sy = 1, rotation = 0, alpha = 1) {
      const [rx, ry, rw, rh] = rect;
      ctx.save();
      ctx.globalAlpha = alpha;
      ctx.translate(x, y);
      ctx.rotate(rotation);
      ctx.scale(sx, sy);
      ctx.drawImage(face, rx, ry, rw, rh, -rw / 2, -rh / 2, rw, rh);
      ctx.restore();
    }
    function drawFace(t, p) {
      ctx.save();
      const nod = Math.sin(t * Math.PI / 3.4) * 1.3;
      drawSceneEyes(ctx, { nod, gazeX: -0.25 * (1 - p.done), gazeY: 0.62 * p.lookY, blink: p.blink });
      feature([536, 154, 128, 85], 600, 196.5 + nod - p.done * 8, 1, 1, -0.025 * p.done);
      feature([838, 205, 157, 103], 916.5, 256.5 + nod - p.done * 8, 1, 1, 0.025 * p.done);
      const open = 0.04 + 0.96 * p.done, scale = 0.1 + 0.98 * open;
      feature([652, 441, 125, 96], 714.5, 466 + 23 * scale + nod, 1, scale, 0, smooth(0.12, 0.4, open));
      const lipAlpha = 1 - smooth(0.06, 0.3, open);
      if (lipAlpha > 1e-3) {
        ctx.save();
        ctx.globalAlpha = lipAlpha;
        ctx.translate(0, nod);
        const lip = ctx.createLinearGradient(674, 463, 757, 493);
        lip.addColorStop(0, "#b89ba5");
        lip.addColorStop(0.5, "#e1cbd0");
        lip.addColorStop(1, "#b89ba5");
        ctx.strokeStyle = lip;
        ctx.lineWidth = 4.2;
        ctx.lineCap = "round";
        ctx.beginPath();
        ctx.moveTo(674, 463);
        ctx.bezierCurveTo(690, 482 - (1 - p.writing) * 3, 727, 497 - (1 - p.writing) * 3, 757, 479);
        ctx.stroke();
        ctx.restore();
      }
      ctx.restore();
    }
    function page(points, front, alpha = 1) {
      const [a, b, c, d] = points;
      ctx.save();
      ctx.globalAlpha = alpha;
      const shade = ctx.createLinearGradient(a[0], a[1], c[0], c[1]);
      shade.addColorStop(0, "#fffbed");
      shade.addColorStop(0.72, "#eee7d5");
      shade.addColorStop(1, "#faf5e8");
      ctx.fillStyle = shade;
      ctx.strokeStyle = "#d5cbb7";
      ctx.lineWidth = 1;
      ctx.beginPath();
      ctx.moveTo(...a);
      ctx.lineTo(...b);
      ctx.lineTo(...c);
      ctx.lineTo(...d);
      ctx.closePath();
      ctx.fill();
      ctx.stroke();
      if (front) {
        const left = b[0] < a[0] ? b : a, right = b[0] < a[0] ? a : b, bottom = b[0] < a[0] ? c : d;
        ctx.transform((right[0] - left[0]) / 200, (right[1] - left[1]) / 200, (bottom[0] - left[0]) / 230, (bottom[1] - left[1]) / 230, ...left);
        ctx.textAlign = "center";
        ctx.fillStyle = "#a44336";
        ctx.font = "600 102px Georgia";
        ctx.fillText("3", 100, 137);
        ctx.font = "600 24px Arial";
        ctx.fillText("\u0441\u0435\u043D\u0442\u044F\u0431\u0440\u044F", 100, 183);
      }
      ctx.restore();
    }
    const initial = [[410, 540], [675, 566], [727, 805], [465, 780]];
    const released = [[704, 500], [904, 510], [890, 744], [690, 730]];
    function peeling(p) {
      return initial.map((v, i) => {
        const q = i === 0 || i === 3 ? smooth(0.48, 1, p) : p;
        return v.map((n, j) => n + (released[i][j] - n) * q);
      });
    }
    function draw2(time2) {
      const t = time2 % 9.6, local = t < 4.4 ? t : t - 4.4;
      const pull = smooth(0.6, 2.05, local), back = smooth(2.5, 3.8, local);
      const hx = 675 + 229 * pull * (1 - back), hy = 566 - 56 * pull * (1 - back);
      const w = canvas2.width, h = canvas2.height;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, w, h);
      const scale = Math.min(w / 1200, h / 900);
      ctx.translate((w - 1200 * scale) / 2, (h - 900 * scale) / 2);
      ctx.scale(scale, scale);
      ctx.translate(-68, -85);
      ctx.drawImage(base, 0, 0);
      if (local < 2.05) {
        ctx.save();
        ctx.beginPath();
        ctx.rect(0, 0, 1536, 1024);
        ctx.moveTo(363, 547);
        ctx.lineTo(405, 532);
        ctx.lineTo(670, 560);
        ctx.lineTo(731, 812);
        ctx.lineTo(688, 850);
        ctx.lineTo(420, 784);
        ctx.closePath();
        ctx.clip("evenodd");
        page(peeling(pull), false);
        ctx.restore();
      }
      const blink = Math.exp(-Math.pow((t - 3.6) / 0.1, 2)) + Math.exp(-Math.pow((t - 8.6) / 0.1, 2));
      drawFace(t, { blink, lookX: 0, lookY: 1 - smooth(7.4, 8.2, t), done: 0.15 + 0.65 * smooth(7.3, 8.5, t), writing: 1 });
      if (local >= 2.05 && local < 4.35) {
        const f = (local - 2.05) / 2.3;
        const flip = Math.cos(Math.PI * smooth(0.04, 0.38, f));
        const angle = 0.3 * Math.sin(f * 4), dx = 75 * Math.sin(f * 2.7), dy = 65 * f + 440 * f * f;
        const points = released.map(([x, y]) => {
          const xx = (x - 797) * flip, yy = y - 622;
          return [797 + dx + xx * Math.cos(angle) - yy * Math.sin(angle), 622 + dy + xx * Math.sin(angle) + yy * Math.cos(angle)];
        });
        page(points, flip < -0.15, 1 - smooth(0.86, 1, f));
      }
      ctx.save();
      ctx.translate(hx, hy);
      ctx.rotate(-0.13 * pull * (1 - back));
      ctx.scale(0.88, 0.88);
      ctx.translate(-723, -576);
      ctx.beginPath();
      ctx.moveTo(713, 566);
      ctx.bezierCurveTo(706, 548, 734, 537, 752, 533);
      ctx.bezierCurveTo(792, 514, 836, 525, 867, 552);
      ctx.bezierCurveTo(890, 572, 902, 613, 896, 640);
      ctx.bezierCurveTo(894, 673, 872, 690, 848, 691);
      ctx.bezierCurveTo(825, 693, 812, 682, 806, 663);
      ctx.bezierCurveTo(784, 666, 768, 655, 762, 641);
      ctx.bezierCurveTo(739, 639, 721, 618, 726, 597);
      ctx.lineTo(736, 584);
      ctx.bezierCurveTo(720, 589, 711, 580, 713, 566);
      ctx.closePath();
      ctx.clip();
      ctx.drawImage(hand, 0, 0);
      ctx.restore();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
    }
    return { draw: draw2, dispose() {
      canvas2.width = 1;
      canvas2.height = 1;
    }, resize(w, h) {
      const d = Math.min(devicePixelRatio || 1, 2);
      canvas2.width = Math.round(w * d);
      canvas2.height = Math.round(h * d);
    } };
  }

  // native/macos/DennyNotchHost/Sources/DennyNotchHostApp/Resources/DennyActivities/source/handwriting.js
  var loop = (cx, cy, rx, ry) => Array.from({ length: 25 }, (_, i) => {
    const a = Math.PI * 2 * i / 24;
    return [cx + rx * Math.cos(a), cy + ry * Math.sin(a)];
  });
  var G = {
    "\u041A": [[[0, 0], [0, 14]], [[8, 0], [0, 8], [9, 14]]],
    "\u041F": [[[0, 14], [0, 0], [8, 0], [8, 14]]],
    "\u041E": [loop(4, 7, 4, 7)],
    "\u043F": [[[0, 14], [0, 5], [8, 5], [8, 14]]],
    "\u0438": [[[0, 5], [0, 14], [8, 5], [8, 14]]],
    "\u0442": [[[0, 5], [8, 5]], [[4, 5], [4, 14]]],
    "\u044C": [[[0, 5], [0, 14], [5, 14], [8, 12], [8, 10], [5, 8], [0, 8]]],
    "\u0445": [[[0, 5], [8, 14]], [[8, 5], [0, 14]]],
    "\u043B": [[[0, 14], [3, 5], [6, 5], [9, 14]]],
    "\u0435": [[[0, 9], [8, 9], [7, 6], [4, 5], [1, 6], [0, 9], [1, 12], [4, 14], [8, 12]]],
    "\u0431": [[[8, 0], [3, 1], [1, 4], [0, 9], [1, 12], [4, 14], [7, 13], [8, 10], [7, 7], [4, 6], [1, 8]]],
    "\u043E": [loop(4, 9.5, 4, 4.5)],
    "\u0437": [[[0, 6], [3, 5], [6, 5], [8, 7], [6, 9], [3, 9], [6, 9], [8, 11], [7, 13], [4, 14], [0, 13]]],
    "\u0432": [[[0, 14], [0, 5], [5, 5], [7, 6], [7, 8], [4, 9], [0, 9]], [[4, 9], [7, 10], [8, 12], [6, 14], [0, 14]]],
    "\u043D": [[[0, 5], [0, 14]], [[0, 9], [8, 9]], [[8, 5], [8, 14]]],
    "\u043C": [[[0, 14], [0, 5], [4, 11], [8, 5], [8, 14]]],
    "\u0430": [loop(4, 9.5, 4, 4.5), [[8, 5], [8, 14]]],
    "\u0434": [[[0, 14], [2, 5], [6, 5], [8, 14]], [[0, 17], [0, 14], [9, 14], [9, 17]]],
    "\u0443": [[[0, 5], [4, 13], [8, 5]], [[4, 13], [2, 17], [0, 18]]]
  };
  var TEXT = ["\u041A\u0443\u043F\u0438\u0442\u044C \u0445\u043B\u0435\u0431", "\u041F\u043E\u0437\u0432\u043E\u043D\u0438\u0442\u044C \u043C\u0430\u043C\u0435", "\u041E\u0442\u0434\u043E\u0445\u043D\u0443\u0442\u044C"];
  var clamp3 = (x) => Math.max(0, Math.min(1, x));
  var mix = (a, b, t) => a + (b - a) * t;
  var smooth2 = (t) => {
    t = clamp3(t);
    return t * t * (3 - 2 * t);
  };
  var paper = (u, v, row) => {
    const x = 718 - row * 24 + 0.62 * u - 0.66 * v, y = 758 + row * 16 + 0.17 * u + 0.5 * v;
    return [2 * 734.5795 - x, 2 * 778.405 - y];
  };
  var lines = TEXT.map((text, row) => {
    let cursor = 0, length = 0;
    const segments = [];
    for (const char of text) {
      if (char === " ") {
        cursor += 6;
        continue;
      }
      if (!G[char]) throw new Error(`Missing handwriting glyph ${char}`);
      for (const stroke of G[char]) {
        const points = stroke.map(([x, y]) => paper(cursor + x, y - 14, row));
        if (segments.length) {
          const from = segments.at(-1).b, to = points[0];
          const len = Math.hypot(to[0] - from[0], to[1] - from[1]) * 0.38 + 2;
          segments.push({ a: from, b: to, start: length, length: len, ink: false });
          length += len;
        }
        for (let i = 1; i < points.length; i++) {
          const a = points[i - 1], b = points[i], len = Math.hypot(b[0] - a[0], b[1] - a[1]);
          segments.push({ a, b, start: length, length: len, ink: true });
          length += len;
        }
      }
      cursor += 11;
    }
    return { text, row, segments, length, start: segments[0].a, end: segments.at(-1).b };
  });
  function sampleLine(line, progress) {
    const distance = clamp3(progress) * line.length;
    const seg = line.segments.find((s) => s.start + s.length >= distance) || line.segments.at(-1);
    const f = clamp3((distance - seg.start) / seg.length);
    return { point: [mix(seg.a[0], seg.b[0], f), mix(seg.a[1], seg.b[1], f)], lift: seg.ink ? 0 : Math.sin(f * Math.PI) * 3 };
  }
  function writingFrame(time2) {
    const t = (time2 % 6.8 + 6.8) % 6.8, row = Math.min(2, Math.floor(Math.min(t, 4.799) / 1.6)), local = t - row * 1.6;
    const amounts = lines.map((_, i) => clamp3((t - i * 1.6) / 1.3));
    let { point, lift } = sampleLine(lines[row], amounts[row]);
    if (local > 1.3 && row < 2) {
      const a = smooth2((local - 1.3) / 0.3), next = lines[row + 1].start;
      point = [mix(point[0], next[0], a), mix(point[1], next[1], a)];
      lift = Math.sin(a * Math.PI) * 11;
    }
    if (t > 4.8) {
      const up = smooth2((t - 4.8) / 0.35);
      lift = 14 * up;
      if (t > 5.9) {
        const a = smooth2((t - 5.9) / 0.65), next = lines[0].start;
        point = [mix(point[0], next[0], a), mix(point[1], next[1], a)];
        lift *= 1 - smooth2((t - 6.5) / 0.3);
      }
    }
    return { point, lift, amounts, inkAlpha: 1 - smooth2((t - 6.05) / 0.6) };
  }
  function drawHandwriting(ctx, frame, done = 0) {
    ctx.save();
    ctx.lineWidth = 1.35;
    ctx.lineCap = "round";
    ctx.lineJoin = "round";
    ctx.strokeStyle = "#61685f";
    ctx.globalAlpha = Math.max(frame.inkAlpha, done);
    lines.forEach((line, i) => {
      const amount = mix(frame.amounts[i], 1, done), distance = amount * line.length;
      ctx.beginPath();
      for (const seg of line.segments) {
        if (seg.start >= distance) break;
        if (!seg.ink) continue;
        const f = clamp3((distance - seg.start) / seg.length);
        ctx.moveTo(...seg.a);
        ctx.lineTo(mix(seg.a[0], seg.b[0], f), mix(seg.a[1], seg.b[1], f));
      }
      ctx.stroke();
    });
    ctx.restore();
  }

  // native/macos/DennyNotchHost/Sources/DennyNotchHostApp/Resources/DennyActivities/source/task-scene.js
  var asset = (name) => new URL(name, document.baseURI).href;
  var clamp4 = (x) => Math.max(0, Math.min(1, x));
  var mix2 = (a, b, t) => a + (b - a) * t;
  var smooth3 = (a, b, x) => {
    const t = clamp4((x - a) / (b - a));
    return t * t * (3 - 2 * t);
  };
  var load2 = (name) => new Promise((resolve, reject) => {
    const image = new Image();
    image.onload = () => resolve(image);
    image.onerror = () => reject(new Error(`Cannot load ${name}`));
    image.src = asset(name);
  });
  async function createTasksScene(canvas2) {
    const [face, book, hand] = await Promise.all([
      load2("notebook-keyframe.png"),
      load2("notebook-cleanplate.png"),
      load2("writer-sprite.png")
    ]);
    const ctx = canvas2.getContext("2d", { alpha: false });
    if (!ctx) throw new Error("Canvas unavailable");
    function feature(rect, x, y, sx = 1, sy = 1, rotation = 0, alpha = 1) {
      const [rx, ry, rw, rh] = rect;
      ctx.save();
      ctx.globalAlpha = alpha;
      ctx.translate(x, y);
      ctx.rotate(rotation);
      ctx.scale(sx, sy);
      ctx.drawImage(face, rx, ry, rw, rh, -rw / 2, -rh / 2, rw, rh);
      ctx.restore();
    }
    function drawFace(t, p) {
      ctx.save();
      const nod = Math.sin(t * Math.PI / 3.4) * 1.3;
      const point = writingFrame(t).point;
      const tracking = 1 - (p.rest ?? 0);
      drawSceneEyes(ctx, { nod, gazeX: p.lookX * 1.5 + (point[0] - 755) / 260 * p.writing * tracking, gazeY: p.lookY * 1.7, blink: p.blink });
      feature([536, 154, 128, 85], 600, 196.5 + nod - p.done * 8, 1, 1, -0.025 * p.done);
      feature([838, 205, 157, 103], 916.5, 256.5 + nod - p.done * 8, 1, 1, 0.025 * p.done);
      const open = 0.04 + 0.96 * p.done, scale = 0.1 + 0.98 * open;
      feature([652, 441, 125, 96], 714.5, 466 + 23 * scale + nod, 1, scale, 0, smooth3(0.12, 0.4, open));
      const lipAlpha = 1 - smooth3(0.06, 0.3, open);
      if (lipAlpha > 1e-3) {
        ctx.save();
        ctx.globalAlpha = lipAlpha;
        ctx.translate(0, nod);
        const lip = ctx.createLinearGradient(674, 463, 757, 493);
        lip.addColorStop(0, "#b89ba5");
        lip.addColorStop(0.5, "#e1cbd0");
        lip.addColorStop(1, "#b89ba5");
        ctx.strokeStyle = lip;
        ctx.lineWidth = 4.2;
        ctx.lineCap = "round";
        ctx.beginPath();
        ctx.moveTo(674, 463);
        ctx.bezierCurveTo(690, 482 - (1 - p.writing) * 3, 727, 497 - (1 - p.writing) * 3, 757, 479);
        ctx.stroke();
        ctx.restore();
      }
      ctx.restore();
    }
    function draw2(time2, p) {
      const t = time2 % 6.8, w = canvas2.width, h = canvas2.height;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, w, h);
      const s = Math.min(w / 1200, h / 800);
      ctx.translate((w - 1200 * s) / 2, (h - 800 * s) / 2);
      ctx.scale(s, s);
      ctx.translate(-68, -96);
      ctx.drawImage(book, 0, 0);
      drawFace(t, p);
      const frame = writingFrame(t);
      drawHandwriting(ctx, frame);
      const rest = [755, 765];
      const restBlend = p.rest ?? 0;
      const nx = mix2(frame.point[0], rest[0] + p.done * 12, restBlend);
      const ny = mix2(frame.point[1], rest[1], restBlend);
      const height = mix2(frame.lift, 10 + 4 * p.done, restBlend);
      ctx.save();
      ctx.translate(nx, ny);
      ctx.scale(1, 0.33);
      const shadow = ctx.createRadialGradient(0, 0, 0.5, 0, 0, 7 + height * 0.3);
      shadow.addColorStop(0, `rgba(30,36,28,${Math.max(0.06, 0.27 - height * 5e-3)})`);
      shadow.addColorStop(1, "rgba(30,36,28,0)");
      ctx.fillStyle = shadow;
      ctx.fillRect(-18, -18, 36, 36);
      ctx.restore();
      ctx.save();
      ctx.translate(nx, ny - height);
      ctx.rotate(9e-3 * Math.sin(t * Math.PI * 2 / 0.425) * p.writing - 0.045 * restBlend);
      ctx.scale(0.7, 0.7);
      ctx.drawImage(hand, 660, 530, 275, 325, 660 - 677, 530 - 824, 275, 325);
      ctx.restore();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
    }
    return { draw: draw2, resize(w, h) {
      const d = Math.min(devicePixelRatio || 1, 1.6);
      canvas2.width = Math.round(w * d);
      canvas2.height = Math.round(h * d);
    }, dispose() {
      canvas2.width = 1;
      canvas2.height = 1;
    } };
  }

  // native/macos/DennyNotchHost/Sources/DennyNotchHostApp/Resources/DennyActivities/source/notes-scene.js
  var NOTES_FPS = 24;
  var NOTES_FRAMES = 362;
  var NOTES_DURATION = NOTES_FRAMES / NOTES_FPS;
  function notesFrame(time2, { reduced: reduced2 = false, loop: loop3 = true } = {}) {
    if (reduced2) return 24;
    const t = Number.isFinite(time2) ? Math.max(0, time2) : 0;
    const i = Math.floor(t * NOTES_FPS);
    return loop3 ? i % NOTES_FRAMES : Math.min(NOTES_FRAMES - 1, i);
  }
  async function createNotesScene(canvas2, { assetBase = new URL("./notes/", document.baseURI).href } = {}) {
    const ctx = canvas2.getContext("2d", { alpha: false });
    if (!ctx) throw new Error("Notes canvas unavailable");
    const pages = /* @__PURE__ */ new Map(), pending = /* @__PURE__ */ new Map(), failed = /* @__PURE__ */ new Map();
    const pageCount = Math.ceil(NOTES_FRAMES / 16);
    let disposed = false, lastFrame = 0, lastDraw = null;
    function trim(center) {
      const keep = /* @__PURE__ */ new Set([center, (center + 1) % pageCount, (center + 2) % pageCount]);
      for (const n of pages.keys()) if (!keep.has(n)) pages.delete(n);
    }
    async function load3(n) {
      n = (n + pageCount) % pageCount;
      if (disposed || pages.has(n)) return;
      if (pending.has(n)) return pending.get(n);
      if (Date.now() - (failed.get(n) || 0) < 5e3) return;
      const task = (async () => {
        try {
          const im = new Image();
          im.src = new URL(`page-${String(n).padStart(2, "0")}.jpg`, assetBase).href;
          await im.decode();
          if (!disposed) {
            pages.set(n, im);
          }
        } catch (e) {
          failed.set(n, Date.now());
          throw e;
        }
      })().finally(() => pending.delete(n));
      pending.set(n, task);
      return task;
    }
    await load3(0);
    await load3(1);
    void load3(2).catch(console.error);
    function draw2(time2, options = {}) {
      if (disposed) return;
      const wanted = notesFrame(time2, options), pn = Math.floor(wanted / 16);
      const request = load3(pn);
      if (pages.has(pn)) lastFrame = wanted;
      else if (pending.has(pn)) void request.then(() => {
        if (lastDraw && !disposed && notesFrame(lastDraw.time, lastDraw.options) === wanted) draw2(lastDraw.time, lastDraw.options);
      }).catch(console.error);
      lastDraw = { time: time2, options };
      const n = Math.floor(lastFrame / 16), im = pages.get(n);
      if (!im) return;
      void load3((n + 1) % pageCount).catch(console.error);
      void load3((n + 2) % pageCount).catch(console.error);
      trim(n);
      const w = canvas2.width, h = canvas2.height, s = Math.min(w / 1024, h / 768), tile = lastFrame % 16;
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.fillStyle = "#000";
      ctx.fillRect(0, 0, w, h);
      ctx.drawImage(im, tile % 4 * 512, Math.floor(tile / 4) * 384, 512, 384, (w - 1024 * s) / 2, (h - 768 * s) / 2, 1024 * s, 768 * s);
      canvas2.dataset.notesFrame = String(lastFrame);
    }
    return { draw: draw2, duration: NOTES_DURATION, resize(w, h) {
      if (disposed) return;
      const d = Math.min(globalThis.devicePixelRatio || 1, 2);
      canvas2.width = Math.max(1, Math.round(w * d));
      canvas2.height = Math.max(1, Math.round(h * d));
    }, dispose() {
      disposed = true;
      pages.clear();
      pending.clear();
      lastDraw = null;
    } };
  }

  // native/macos/DennyNotchHost/Sources/DennyNotchHostApp/Resources/DennyActivities/source/activity.js
  var canvas = document.querySelector("canvas");
  var smooth4 = (a, b, t) => {
    const u = Math.max(0, Math.min(1, (t - a) / (b - a)));
    return u * u * (3 - 2 * u);
  };
  var bump = (a, b, c, d, t) => smooth4(a, b, t) * (1 - smooth4(c, d, t));
  var scene;
  var mode = null;
  var reduced = false;
  var paused = false;
  var time = 0;
  var raf = 0;
  var last = 0;
  var frameAt = 0;
  var generation = 0;
  function draw() {
    if (!scene) return;
    if (mode === "calendar") {
      scene.draw(time);
      return;
    }
    if (mode === "tasks") {
      const t = time % 6.8, writing = 1 - bump(4.8, 5.1, 5.9, 6.5, t);
      scene.draw(t, { writing, done: 0, rest: 0, blink: Math.max(bump(2.72, 2.78, 2.82, 2.94, t), bump(6.02, 6.08, 6.12, 6.24, t)), lookX: 0.22 - 0.4 * writing, lookY: -0.15 + 0.47 * writing });
    } else {
      scene.draw(time, { reduced, loop: false });
    }
  }
  function stop() {
    cancelAnimationFrame(raf);
    raf = 0;
    last = 0;
  }
  function loop2(now) {
    raf = 0;
    if (!scene || paused || reduced || document.hidden) return;
    time += Math.min(0.1, Math.max(0, (now - last) / 1e3));
    last = now;
    if (now - frameAt >= 1e3 / 24) {
      frameAt = now;
      draw();
    }
    raf = requestAnimationFrame(loop2);
  }
  function wake() {
    if (!raf && scene && !paused && !reduced && !document.hidden) {
      last = performance.now();
      raf = requestAnimationFrame(loop2);
    }
  }
  function resize() {
    if (scene) {
      scene.resize(innerWidth, innerHeight);
      draw();
    }
  }
  window.setDennyPaused = (value) => {
    paused = !!value;
    if (paused) stop();
    else wake();
  };
  window.setDennyActivity = async (next, reduce) => {
    if (next !== "notes" && next !== "tasks" && next !== "calendar") return;
    reduced = !!reduce;
    if (mode === next) {
      if (reduced) stop();
      draw();
      wake();
      return;
    }
    const token = ++generation;
    stop();
    scene?.dispose();
    scene = null;
    mode = next;
    try {
      const loaded = await (next === "calendar" ? createCalendarScene(canvas) : next === "tasks" ? createTasksScene(canvas) : createNotesScene(canvas));
      if (token !== generation) return;
      scene = loaded;
      time = reduced ? next === "calendar" ? 3 : next === "tasks" ? 4.6 : 1.8 : 0;
      resize();
      wake();
    } catch (error) {
      console.error("Denny activity unavailable", error);
    }
  };
  new ResizeObserver(resize).observe(document.body);
  document.addEventListener("visibilitychange", () => {
    if (document.hidden) stop();
    else wake();
  });
  addEventListener("pagehide", stop);
})();
