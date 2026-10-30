// Showcase carousel: a scroll-snap track with arrows, dots and a gentle autoplay
// that stops for good once the visitor takes over.
document.querySelectorAll("[data-carousel]").forEach((root) => {
  const track = root.querySelector(".showcase-track");
  const slides = [...track.children];
  const dots = root.querySelector(".dots");
  const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  let index = 0;
  let timer = null;

  const dotButtons = slides.map((slide, i) => {
    const b = document.createElement("button");
    b.type = "button";
    b.setAttribute("role", "tab");
    b.setAttribute("aria-label", slide.querySelector("strong").textContent);
    b.addEventListener("click", () => { stop(); go(i); });
    dots.appendChild(b);
    return b;
  });

  const go = (i) => {
    index = (i + slides.length) % slides.length;
    track.scrollTo({ left: slides[index].offsetLeft - track.offsetLeft, behavior: reduceMotion ? "auto" : "smooth" });
  };

  const mark = (i) => {
    index = i;
    dotButtons.forEach((b, k) => b.setAttribute("aria-selected", String(k === i)));
    slides.forEach((s, k) => {
      const v = s.querySelector("video");
      if (v) k === i && !reduceMotion ? v.play().catch(() => {}) : v.pause();
    });
  };

  // Which slide is on show follows the scroll position (arrows, dots, swipes).
  const onShow = new IntersectionObserver((entries) => {
    entries.forEach((e) => { if (e.isIntersecting) mark(slides.indexOf(e.target)); });
  }, { root: track, threshold: 0.6 });
  slides.forEach((s) => onShow.observe(s));

  const stop = () => { clearInterval(timer); timer = null; };
  root.querySelector("[data-prev]").addEventListener("click", () => { stop(); go(index - 1); });
  root.querySelector("[data-next]").addEventListener("click", () => { stop(); go(index + 1); });
  track.addEventListener("keydown", (e) => {
    if (e.key === "ArrowRight") { e.preventDefault(); stop(); go(index + 1); }
    if (e.key === "ArrowLeft") { e.preventDefault(); stop(); go(index - 1); }
  });
  ["pointerdown", "wheel", "touchstart"].forEach((ev) => track.addEventListener(ev, stop, { passive: true }));

  mark(0);
  if (!reduceMotion) timer = setInterval(() => go(index + 1), 5000);
});

// The Remote Agent section that fetched the relay's agent version.json went
// away with T1175 (one Windows installer carries the agent), so nothing on
// the page fetches it.
