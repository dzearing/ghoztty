// Showcase carousel: stacked slides that crossfade, with arrows, dots, swipes
// and a gentle autoplay that stops for good once the visitor takes over.
document.querySelectorAll("[data-carousel]").forEach((root) => {
  const track = root.querySelector(".showcase-track");
  const slides = [...track.children];
  const dots = root.querySelector(".dots");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let index = 0;
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
    b.setAttribute("role", "tab");
    b.setAttribute("aria-label", slide.querySelector("strong").textContent);
    b.addEventListener("click", () => { stop(); go(i); });
    dots.appendChild(b);
    return b;
  });

  // A slide's image loads before the carousel shows it, so it never fades in
  // a half-decoded picture. Neighbours load ahead of time.
  const ready = (k) => {
    const img = slides[(k + slides.length) % slides.length].querySelector("img");
    if (!img) return Promise.resolve();
    img.loading = "eager";
    const decoded = img.decode ? img.decode().catch(() => {}) : Promise.resolve();
    return Promise.race([decoded, new Promise((r) => setTimeout(r, 4000))]);
  };

  const show = (i) => {
    index = i;
    slides.forEach((s, k) => {
      s.classList.toggle("is-on", k === i);
      s.setAttribute("aria-hidden", String(k !== i));
      const v = s.querySelector(".slide-media video");
      if (v) k === i && !reduceMotion ? v.play().catch(() => {}) : v.pause();
    });
    dotButtons.forEach((b, k) => b.setAttribute("aria-selected", String(k === i)));
    ready(i + 1);
    ready(i - 1);
  };

  let pending = 0;
  const go = async (i) => {
    const target = (i + slides.length) % slides.length;
    const ticket = ++pending;
    await ready(target);
    if (ticket !== pending) return; // a newer request superseded this one
    show(target);
  };

  const stop = () => { clearInterval(timer); timer = null; };
  root.querySelector("[data-prev]").addEventListener("click", () => { stop(); go(index - 1); });
  root.querySelector("[data-next]").addEventListener("click", () => { stop(); go(index + 1); });
  track.addEventListener("keydown", (e) => {
    if (e.key === "ArrowRight") { e.preventDefault(); stop(); go(index + 1); }
    if (e.key === "ArrowLeft") { e.preventDefault(); stop(); go(index - 1); }
  });

  // A horizontal swipe moves one slide.
  let startX = null;
  track.addEventListener("pointerdown", (e) => { startX = e.clientX; stop(); });
  track.addEventListener("pointerup", (e) => {
    if (startX === null) return;
    const dx = e.clientX - startX;
    startX = null;
    if (Math.abs(dx) > 40) go(index + (dx < 0 ? 1 : -1));
  });

  show(0);
  // Then warm every remaining slide once the page has settled.
  window.addEventListener("load", () => {
    const warm = () => slides.forEach((_, k) => ready(k));
    "requestIdleCallback" in window ? requestIdleCallback(warm) : setTimeout(warm, 1500);
  });
  // Autoplay only advances while the page is on screen.
  if (!reduceMotion) timer = setInterval(() => { if (!document.hidden) go(index + 1); }, 5000);
});

// The Remote Agent section that fetched the relay's agent version.json went
// away with T1175 (one Windows installer carries the agent), so nothing on
// the page fetches it.
