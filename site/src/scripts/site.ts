// Small things the pages do: the shots' notification and mini player, the ghost-mode switches,
// the theme switch, copy buttons and the nav's backdrop once the page scrolls. Motion only
// where it shows what the app does, and none with Reduce Motion.

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

// The shots' notification and mini player play once: the hero's after the page's entrance,
// the others when they come into view.
const heroShot = document.querySelector<HTMLElement>('[data-hero]');
if (heroShot) setTimeout(() => heroShot.classList.add('play'), still ? 0 : 700);
watch(
  [...document.querySelectorAll('[data-shot]')].filter((el) => el !== heroShot),
  (el) => el.classList.add('play'),
  0.4,
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
      if (target[i] === 'true') setTimeout(() => s.setAttribute('aria-checked', 'true'), 300 + i * 300);
    });
  }, 0.5);
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
