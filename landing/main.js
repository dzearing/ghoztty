// Showcase carousel: a row of screenshots in 3D that glides with a trackpad
// swipe, a drag, the arrow keys, the arrows or the dots, plus a gentle
// autoplay that stops for good once the visitor takes over.
document.querySelectorAll("[data-carousel]").forEach((root) => {
  const track = root.querySelector(".showcase-track");
  const slides = [...track.children];
  const count = slides.length;
  const dots = root.querySelector(".dots");
  const caption = root.querySelector(".showcase-caption");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let timer = null;

  // A flipped copy of each screenshot makes the reflection under it. A video's
  // reflection shows its poster; the motion is too small to notice there.
  slides.forEach((slide) => {
    const media = slide.querySelector(".slide-media");
    const copy = media.cloneNode(true);
    copy.querySelectorAll("img").forEach((img) => { img.alt = ""; img.removeAttribute("fetchpriority"); });
    copy.querySelectorAll("video").forEach((video) => {
      const poster = document.createElement("img");
      poster.src = video.poster;
      poster.alt = "";
      poster.width = video.width;
      poster.height = video.height;
      video.replaceWith(poster);
    });
    const reflection = document.createElement("div");
    reflection.className = "reflection";
    reflection.setAttribute("aria-hidden", "true");
    reflection.appendChild(copy);
    media.after(reflection);
  });

  const dotButtons = slides.map((slide, i) => {
    const b = document.createElement("button");
    b.type = "button";
    // WebKit leaves buttons out of Tab order unless they ask to be in it.
    b.tabIndex = 0;
    b.setAttribute("aria-label", `${i + 1} of ${count}: ${slide.querySelector("strong").textContent}`);
    b.addEventListener("click", () => { stop(); glideTo(i); });
    dots.appendChild(b);
    return b;
  });

  // `pos` is the slide at the centre, fractional while gliding. The row wraps
  // around, so each slide sits at its shortest distance from the centre.
  let pos = 0;
  let target = 0;
  let current = -1;
  const wrap = (x) => ((x % count) + count) % count;
  const offsetOf = (i) => {
    let o = i - pos;
    o -= Math.round(o / count) * count;
    return o;
  };

  const place = () => {
    const w = slides[0].offsetWidth;
    slides.forEach((slide, i) => {
      const o = offsetOf(i);
      const a = Math.abs(o);
      const near = Math.min(a, 1);
      const far = Math.max(a - 1, 0);
      const x = Math.sign(o) * (near * 0.76 + far * 0.24) * w;
      const z = -(near * 0.5 + far * 0.2) * w;
      const turn = -Math.max(-1, Math.min(1, o)) * 42;
      slide.style.transform = `translate3d(${x.toFixed(1)}px, 0, ${z.toFixed(1)}px) rotateY(${turn.toFixed(2)}deg)`;
      slide.style.opacity = String(Math.max(0, Math.min(1, 1 - near * 0.4 - far * 0.45)));
      slide.style.zIndex = String(100 - Math.round(a * 10));
      slide.style.visibility = a > 2.4 ? "hidden" : "visible";
    });
    const nearest = wrap(Math.round(pos));
    if (nearest !== current) settle(nearest);
  };

  // When a new slide reaches the centre: its caption, its dot, its video.
  const settle = (i) => {
    current = i;
    slides.forEach((s, k) => {
      s.setAttribute("aria-hidden", String(k !== i));
      const v = s.querySelector(".slide-media video");
      if (v) k === i && !reduceMotion ? v.play().catch(() => {}) : v.pause();
    });
    dotButtons.forEach((b, k) => k === i ? b.setAttribute("aria-current", "true") : b.removeAttribute("aria-current"));
    caption.classList.add("fading");
    clearTimeout(caption.swap);
    caption.swap = setTimeout(() => {
      caption.innerHTML = slides[i].querySelector("figcaption").innerHTML;
      caption.classList.remove("fading");
    }, reduceMotion ? 0 : 160);
  };

  // Ease `pos` toward `target` each frame; input moves `pos` directly.
  let frame = 0;
  let last = 0;
  const step = (now) => {
    const dt = Math.min(64, now - (last || now));
    last = now;
    const k = reduceMotion ? 1 : 1 - Math.exp(-dt / 140);
    pos += (target - pos) * k;
    if (Math.abs(target - pos) < 0.0005) pos = target;
    place();
    frame = pos === target ? 0 : requestAnimationFrame(step);
    if (!frame) last = 0;
  };
  const animate = () => { if (!frame) frame = requestAnimationFrame(step); };

  // Glide to the copy of slide i nearest the current position, once its image
  // has loaded, so a half-decoded picture never comes to the centre.
  const ready = (i) => {
    const img = slides[wrap(i)].querySelector("img");
    if (!img || (img.complete && img.naturalWidth)) return Promise.resolve();
    const decoded = img.decode ? img.decode().catch(() => {}) : Promise.resolve();
    return Promise.race([decoded, new Promise((r) => setTimeout(r, 4000))]);
  };
  let ticket = 0;
  const glideTo = async (i) => {
    const mine = ++ticket;
    await ready(i);
    if (mine !== ticket) return;
    let d = wrap(i) - wrap(Math.round(target));
    d -= Math.round(d / count) * count;
    target = Math.round(target) + d;
    animate();
  };
  const nudge = (d) => { stop(); glideTo(Math.round(target) + d); };

  root.querySelector("[data-prev]").addEventListener("click", () => nudge(-1));
  root.querySelector("[data-next]").addEventListener("click", () => nudge(1));
  track.addEventListener("keydown", (e) => {
    if (e.key === "ArrowRight") { e.preventDefault(); nudge(1); }
    if (e.key === "ArrowLeft") { e.preventDefault(); nudge(-1); }
  });

  // A sideways trackpad swipe or shift-wheel moves the row with the fingers,
  // then it settles on the nearest slide.
  let wheelEnd = 0;
  track.addEventListener("wheel", (e) => {
    const dx = Math.abs(e.deltaX) > Math.abs(e.deltaY) ? e.deltaX : e.shiftKey ? e.deltaY : 0;
    if (!dx) return;
    e.preventDefault();
    stop();
    ++ticket;
    pos += dx / (slides[0].offsetWidth * 0.76);
    target = pos;
    place();
    clearTimeout(wheelEnd);
    wheelEnd = setTimeout(() => { target = Math.round(pos); animate(); }, 90);
  }, { passive: false });

  // A drag moves it the same way and a flick carries on a little.
  let drag = null;
  track.addEventListener("pointerdown", (e) => {
    stop();
    ++ticket;
    drag = { x: e.clientX, pos, v: 0, t: e.timeStamp, lastX: e.clientX };
    track.setPointerCapture(e.pointerId);
    track.classList.add("dragging");
  });
  track.addEventListener("pointermove", (e) => {
    if (!drag) return;
    const span = slides[0].offsetWidth * 0.76;
    const dt = Math.max(1, e.timeStamp - drag.t);
    drag.v = (drag.lastX - e.clientX) / span / dt;
    drag.t = e.timeStamp;
    drag.lastX = e.clientX;
    pos = drag.pos + (drag.x - e.clientX) / span;
    target = pos;
    place();
  });
  const release = () => {
    if (!drag) return;
    target = Math.round(pos + Math.max(-2, Math.min(2, drag.v * 180)));
    drag = null;
    track.classList.remove("dragging");
    animate();
  };
  track.addEventListener("pointerup", release);
  track.addEventListener("pointercancel", release);

  const stop = () => { clearInterval(timer); timer = null; };
  window.addEventListener("resize", place);
  place();
  // Then warm every slide once the page has settled.
  window.addEventListener("load", () => {
    const warm = () => slides.forEach((_, k) => ready(k));
    "requestIdleCallback" in window ? requestIdleCallback(warm) : setTimeout(warm, 1500);
  });
  // Autoplay only advances while the page is on screen.
  if (!reduceMotion) timer = setInterval(() => { if (!document.hidden) glideTo(Math.round(target) + 1); }, 5000);
});

// The Remote Agent section that fetched the relay's agent version.json went
// away with T1175 (one Windows installer carries the agent), so nothing on
// the page fetches it.
