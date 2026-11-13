// Small things the pages do: reveal on scroll, the shots' entrances, the hero's tilt and the
// shots' drift with the scroll, the theme switch, copy buttons, the nav's backdrop once the
// page scrolls, and the ghost-mode switches. Motion is skipped with Reduce Motion.

declare global {
  interface Window {
    matteSetTheme?: (t: 'light' | 'dark') => void;
  }
}

const still = matchMedia('(prefers-reduced-motion: reduce)').matches;

const watch = (els: Iterable<Element>, onIn: (el: HTMLElement) => void, threshold = 0.08) => {
  if (!('IntersectionObserver' in window)) {
    for (const el of els) onIn(el as HTMLElement);
    return;
  }
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          onIn(e.target as HTMLElement);
          io.unobserve(e.target);
        }
      }
    },
    { rootMargin: '0px 0px -8% 0px', threshold },
  );
  for (const el of els) io.observe(el);
};

watch(document.querySelectorAll('[data-reveal]'), (el) => el.classList.add('in'));
// The hero's window plays once it has risen into place; the others as they come into view.
const heroShot = document.querySelector<HTMLElement>('[data-tilt] [data-shot]');
if (heroShot) setTimeout(() => heroShot.classList.add('play'), still ? 0 : 900);
watch(
  [...document.querySelectorAll('[data-shot]')].filter((el) => el !== heroShot),
  (el) => el.classList.add('play'),
  0.3,
);

// Ghost mode: the switches flip on one after the other when they come into view (without
// JavaScript or with Reduce Motion they simply show their settings).
const ghost = document.querySelector<HTMLElement>('[data-ghost]');
if (ghost && !still) {
  const switches = [...ghost.querySelectorAll<HTMLButtonElement>('[data-switch]')];
  const target = switches.map((s) => s.getAttribute('aria-checked'));
  switches.forEach((s) => s.setAttribute('aria-checked', 'false'));
  watch([ghost], () => {
    switches.forEach((s, i) => {
      if (target[i] === 'true') setTimeout(() => s.setAttribute('aria-checked', 'true'), 500 + i * 450);
    });
  }, 0.5);
}

// Scroll-linked motion: the hero window starts tilted back and settles as the page scrolls;
// the other shots drift slightly against the scroll.
const tilt = document.querySelector<HTMLElement>('[data-tilt]');
const drifting = [...document.querySelectorAll<HTMLElement>('[data-drift] [data-shot]')];
if (!still && (tilt || drifting.length)) {
  let queued = false;
  const frame = () => {
    queued = false;
    const vh = window.innerHeight;
    if (tilt) {
      const top = tilt.getBoundingClientRect().top;
      const p = Math.min(1, Math.max(0, 1 - (top - vh * 0.18) / (vh * 0.55)));
      tilt.style.setProperty('--p', p.toFixed(3));
    }
    for (const el of drifting) {
      const r = el.getBoundingClientRect();
      if (r.bottom < -200 || r.top > vh + 200) continue;
      const offset = (r.top + r.height / 2 - vh / 2) * -0.06;
      el.style.setProperty('--py', `${offset.toFixed(1)}px`);
    }
  };
  const queue = () => {
    if (!queued) {
      queued = true;
      requestAnimationFrame(frame);
    }
  };
  frame();
  window.addEventListener('scroll', queue, { passive: true });
  window.addEventListener('resize', queue);
}

for (const btn of document.querySelectorAll<HTMLButtonElement>('[data-theme-toggle]')) {
  btn.addEventListener('click', () => {
    const next = document.documentElement.dataset.theme === 'light' ? 'dark' : 'light';
    window.matteSetTheme?.(next);
  });
}

for (const btn of document.querySelectorAll<HTMLButtonElement>('[data-copy]')) {
  btn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(btn.dataset.copy ?? '');
      btn.classList.add('copied');
      setTimeout(() => btn.classList.remove('copied'), 1600);
    } catch {
      /* The command stays visible to copy by hand. */
    }
  });
}

const nav = document.querySelector<HTMLElement>('[data-nav]');
if (nav) {
  const update = () => nav.classList.toggle('scrolled', window.scrollY > 8);
  update();
  window.addEventListener('scroll', update, { passive: true });
}

for (const sw of document.querySelectorAll<HTMLButtonElement>('[data-switch]')) {
  sw.addEventListener('click', () => {
    const on = sw.getAttribute('aria-checked') !== 'true';
    sw.setAttribute('aria-checked', String(on));
  });
}

export {};
