// Small things the pages do: reveal on scroll, the theme switch, copy buttons, the nav's
// backdrop once the page scrolls, and the ghost-mode switches.

declare global {
  interface Window {
    matteSetTheme?: (t: 'light' | 'dark') => void;
  }
}

const reveal = document.querySelectorAll<HTMLElement>('[data-reveal]');
if ('IntersectionObserver' in window) {
  const io = new IntersectionObserver(
    (entries) => {
      for (const e of entries) {
        if (e.isIntersecting) {
          e.target.classList.add('in');
          io.unobserve(e.target);
        }
      }
    },
    { rootMargin: '0px 0px -8% 0px', threshold: 0.08 },
  );
  reveal.forEach((el) => io.observe(el));
} else {
  reveal.forEach((el) => el.classList.add('in'));
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
