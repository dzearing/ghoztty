// Command explorer: an ARIA tab list. Arrow keys move between tabs.
document.querySelectorAll("[data-tabs]").forEach((root) => {
  const tabs = [...root.querySelectorAll('[role="tab"]')];
  const select = (tab, focus) => {
    tabs.forEach((t) => {
      const on = t === tab;
      t.setAttribute("aria-selected", String(on));
      t.tabIndex = on ? 0 : -1;
      document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
    });
    if (focus) tab.focus();
  };
  tabs.forEach((tab, i) => {
    tab.addEventListener("click", () => select(tab, false));
    tab.addEventListener("keydown", (e) => {
      const step = { ArrowDown: 1, ArrowRight: 1, ArrowUp: -1, ArrowLeft: -1 }[e.key];
      if (step) {
        e.preventDefault();
        select(tabs[(i + step + tabs.length) % tabs.length], true);
      } else if (e.key === "Home" || e.key === "End") {
        e.preventDefault();
        select(tabs[e.key === "Home" ? 0 : tabs.length - 1], true);
      }
    });
  });
});

// Copy buttons on every code block.
document.querySelectorAll("pre.code").forEach((pre) => {
  const btn = document.createElement("button");
  btn.type = "button";
  btn.className = "copy-btn";
  btn.textContent = "Copy";
  btn.setAttribute("aria-label", "Copy command");
  btn.addEventListener("click", async () => {
    try {
      await navigator.clipboard.writeText(pre.querySelector("code").innerText);
      btn.textContent = "Copied";
    } catch {
      btn.textContent = "Select & copy";
    }
    setTimeout(() => (btn.textContent = "Copy"), 1600);
  });
  pre.appendChild(btn);
});

const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Clips play only while on screen (and never when motion is reduced).
const clipObserver = new IntersectionObserver((entries) => {
  entries.forEach(({ target, isIntersecting }) => {
    if (isIntersecting && !reduceMotion) target.play().catch(() => {});
    else target.pause();
  });
}, { threshold: 0.25 });
document.querySelectorAll("video").forEach((v) => {
  v.removeAttribute("autoplay");
  clipObserver.observe(v);
});

// Gentle reveal on scroll.
if (!reduceMotion && "IntersectionObserver" in window) {
  const revealObserver = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (entry.isIntersecting) {
        entry.target.classList.add("visible");
        revealObserver.unobserve(entry.target);
      }
    });
  }, { threshold: 0.12, rootMargin: "0px 0px -40px 0px" });
  document.querySelectorAll(".pillar, .section-head, .feature, .callout, .card, .steps li, .download .section-inner")
    .forEach((el) => {
      el.classList.add("reveal");
      revealObserver.observe(el);
    });
}

// The Remote Agent section that fetched the relay's agent version.json went
// away with T1175 (one Windows installer carries the agent), so nothing on
// the page fetches it.
