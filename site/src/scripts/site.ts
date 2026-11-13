import gsap from 'gsap';
import { ScrollTrigger } from 'gsap/ScrollTrigger';
import { SplitText } from 'gsap/SplitText';
import { CustomEase } from 'gsap/CustomEase';

// The site's behaviour and motion. Motion follows what Matte does: story bars that fill as
// you read, the hero window coming forward, a reel that leaves its window for the corner
// while another page comes in front, a reel that keeps playing in the page's corner, a
// message arriving. With Reduce Motion everything simply shows.

gsap.registerPlugin(ScrollTrigger, SplitText, CustomEase);

declare global {
  interface Window {
    matteSetTheme?: (t: 'light' | 'dark') => void;
    matteMotion?: boolean;
  }
}

// One easing curve for the page, the same as --ease in the styles.
const ease = CustomEase.create('matte', '0.22,1,0.36,1');
window.matteMotion = true;

const root = document.documentElement;
const $ = <T extends Element = HTMLElement>(s: string, from: ParentNode = document) => from.querySelector<T>(s);
const $$ = <T extends Element = HTMLElement>(s: string, from: ParentNode = document) => [...from.querySelectorAll<T>(s)];

// ─── Small things ────────────────────────────────────────────────────────────────────────

for (const btn of $$<HTMLButtonElement>('[data-theme-toggle]')) {
  btn.addEventListener('click', () => {
    window.matteSetTheme?.(root.dataset.theme === 'light' ? 'dark' : 'light');
  });
}

for (const btn of $$<HTMLButtonElement>('[data-copy]')) {
  btn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(btn.dataset.copy ?? '');
    } catch {
      return;
    }
    btn.classList.add('copied');
    setTimeout(() => btn.classList.remove('copied'), 1600);
  });
}

for (const sw of $$<HTMLButtonElement>('[data-switch]')) {
  sw.addEventListener('click', () => sw.setAttribute('aria-checked', String(sw.getAttribute('aria-checked') !== 'true')));
}

const nav = $('[data-nav]');
const dock = $('[data-dock]');

// ─── Story bars: one segment per section, filling as the page is read ─────────────────────

const bars = $('[data-story-bars]');
const chapters = $$('main > section');
let fills: HTMLElement[] = [];
const layoutBars = () => {
  if (!bars) return;
  bars.replaceChildren();
  fills = chapters.map(() => {
    const seg = document.createElement('i');
    const fill = document.createElement('b');
    seg.append(fill);
    bars.append(seg);
    return fill;
  });
};

let queued = false;
const paint = () => {
  queued = false;
  nav?.classList.toggle('scrolled', scrollY > 8);
  const max = Math.max(1, root.scrollHeight - innerHeight);
  dock?.style.setProperty('--page-progress', String(Math.min(1, scrollY / max)));
  // A section fills as the window's bottom edge moves through it; the last one fills at the end.
  const line = scrollY + innerHeight;
  chapters.forEach((section, i) => {
    const r = section.getBoundingClientRect();
    const top = r.top + scrollY;
    const p = scrollY >= max - 2 ? 1 : Math.min(1, Math.max(0, (line - top) / Math.max(1, r.height)));
    if (fills[i]) fills[i].style.transform = `scaleX(${p})`;
  });
};
const queue = () => {
  if (!queued) {
    queued = true;
    requestAnimationFrame(paint);
  }
};
layoutBars();
paint();
addEventListener('scroll', queue, { passive: true });
addEventListener('resize', queue);

// The page's corner player closes for good when asked.
let dockClosed = false;
$('[data-dock-close]')?.addEventListener('click', () => {
  dockClosed = true;
  dock?.classList.remove('on');
});

// ─── Motion ────────────────────────────────────────────────────────────────────────────

const mm = gsap.matchMedia();

mm.add('(prefers-reduced-motion: reduce)', () => {
  root.classList.add('loaded');
  for (const el of $$('[data-shot]')) el.classList.add('play');
});

// The hero held in place: the words step back and the window comes forward to fill the room.
mm.add('(min-width: 1000px) and (prefers-reduced-motion: no-preference)', () => {
  const text = $('[data-hero-text]');
  const win = $('[data-hero-window]');
  if (!text || !win) return;
  gsap.set(win, { scale: 0.9, transformOrigin: '50% 0%' });
  const tl = gsap.timeline({
    scrollTrigger: { trigger: '[data-hero]', start: 'top top', end: '+=70%', pin: true, scrub: 0.5, invalidateOnRefresh: true },
  });
  tl.to(text, { autoAlpha: 0, y: -40, duration: 0.45, ease: 'none' }, 0);
  tl.to(win, { y: () => -(text.offsetHeight + 8), scale: 1, duration: 1, ease: 'power1.inOut' }, 0);
  return () => {
    gsap.set([text, win], { clearProps: 'all' });
  };
});

mm.add('(prefers-reduced-motion: no-preference)', () => {
  // Headlines come up line by line from behind a mask. The split waits for the fonts.
  const splitLines = (el: HTMLElement, vars: gsap.TweenVars) => {
    gsap.set(el, { opacity: 1 });
    SplitText.create(el, {
      type: 'lines',
      mask: 'lines',
      linesClass: 'split-line',
      autoSplit: true,
      onSplit: (self) => gsap.from(self.lines, { yPercent: 110, duration: 0.8, ease, stagger: 0.07, ...vars }),
    });
  };

  document.fonts.ready.then(() => {
    const title = $('[data-hero-title]');
    if (title) splitLines(title, { delay: 0.05 });
    gsap.fromTo('[data-hero-fade]', { opacity: 0, y: 12 }, { opacity: 1, y: 0, duration: 0.6, ease, stagger: 0.07, delay: 0.35 });
    gsap.fromTo('[data-hero-window] [data-shot]', { opacity: 0, y: 40 }, { opacity: 1, y: 0, duration: 1, ease, delay: 0.5 });
    for (const h of $$('[data-title]')) splitLines(h, { scrollTrigger: { trigger: h, start: 'top 88%', once: true } });
    root.classList.add('loaded');
    // The hero's message and mini player arrive once the window has.
    const heroShot = $('[data-hero-window] [data-shot]');
    if (heroShot) gsap.delayedCall(1.1, () => heroShot.classList.add('play'));
  });

  // Reveals: a short fade and rise, in reading order.
  const rise = (selector: string, stagger = 0.06) => {
    gsap.set(selector, { opacity: 0 });
    ScrollTrigger.batch(selector, {
      start: 'top 90%',
      once: true,
      onEnter: (els) => gsap.fromTo(els, { opacity: 0, y: 14 }, { opacity: 1, y: 0, duration: 0.6, ease, stagger }),
    });
  };
  rise('[data-reveal]');
  rise('[data-row]', 0.04);

  // Each window comes forward as it scrolls into view; its notification or mini player
  // plays once it has arrived.
  for (const media of $$('[data-rise]')) {
    gsap.fromTo(media, { scale: 0.94, y: 56 }, { scale: 1, y: 0, ease: 'none', scrollTrigger: { trigger: media, start: 'top 100%', end: 'top 45%', scrub: 0.5 } });
    const shot = $('[data-shot]', media);
    if (shot) ScrollTrigger.create({ trigger: media, start: 'top 55%', once: true, onEnter: () => shot.classList.add('play') });
  }

  // Reels: the reel leaves its place in the Reels window and settles in the corner while
  // Home comes to the front, the way Matte's mini player works. Transforms only.
  const scene = $('[data-pip-scene]');
  const reel = scene && $('[data-pip-reel]', scene);
  const slot = scene && $('[data-pip-slot]', scene);
  if (scene && reel && slot) {
    const tl = gsap.timeline({
      scrollTrigger: { trigger: scene, start: 'top 70%', end: 'center 38%', scrub: 0.5, invalidateOnRefresh: true },
    });
    tl.fromTo($('[data-pip-other]', scene), { scale: 0.96, opacity: 0 }, { scale: 1, opacity: 1, ease: 'power1.out', duration: 0.8 }, 0.25);
    tl.fromTo(
      reel,
      {
        x: () => slot.offsetLeft - reel.offsetLeft,
        y: () => slot.offsetTop - reel.offsetTop,
        scale: () => slot.offsetWidth / reel.offsetWidth,
      },
      { x: 0, y: 0, scale: 1, ease: 'power1.inOut', duration: 1 },
      0.2,
    );
    tl.to({}, { duration: 0.1 });
  }

  // The page's own mini player: from the end of the hero until the Reels scene takes over.
  if (dock && scene) {
    ScrollTrigger.create({
      trigger: '[data-hero]',
      start: 'bottom top+=96',
      endTrigger: scene,
      end: 'top 70%',
      onToggle: (self) => dock.classList.toggle('on', self.isActive && !dockClosed),
    });
  }

  // Ghost mode: the switches flip on in turn when they come into view.
  const ghost = $('[data-ghost]');
  if (ghost) {
    const switches = $$<HTMLButtonElement>('[data-switch]', ghost);
    const target = switches.map((s) => s.getAttribute('aria-checked'));
    switches.forEach((s) => s.setAttribute('aria-checked', 'false'));
    ScrollTrigger.create({
      trigger: ghost,
      start: 'top 70%',
      once: true,
      onEnter: () =>
        switches.forEach((s, i) => {
          if (target[i] === 'true') gsap.delayedCall(0.3 + i * 0.3, () => s.setAttribute('aria-checked', 'true'));
        }),
    });
  }

  // Image decoding and font loading move the layout.
  addEventListener('load', () => ScrollTrigger.refresh());
});

ScrollTrigger.addEventListener('refresh', paint);

export {};
