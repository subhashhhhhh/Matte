// The README's images (docs/images/) and the website's screenshots (site/public/shots/, light
// and dark): React components that a headless browser photographs. The app's windows are drawn
// in app.jsx, not screenshotted: made-up accounts, generated artwork, no one's real photos or messages.
// `npm install && npm run render` in this folder after a change, then commit the images.
// Needs macOS (the wordmark is Snell Roundhand, the app's text is the system font).
import React from 'react';
import { chromium } from 'playwright';
import { renderToStaticMarkup } from 'react-dom/server';
import sharp from 'sharp';
import { mkdirSync } from 'node:fs';
import { Icon, Window, Home, Messages, Reels, Planner, Mini, Toast, appCss, setGrain } from './app.jsx';
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const here = dirname(fileURLToPath(import.meta.url));
const out = join(here, '..', 'images');
const site = join(here, '..', '..', 'site', 'public');
const dataUrl = (bytes, type) => `data:${type};base64,${Buffer.from(bytes).toString('base64')}`;
const file = (path, type) => dataUrl(readFileSync(join(here, path)), type);

const sans = file('node_modules/@fontsource-variable/instrument-sans/files/instrument-sans-latin-wght-normal.woff2', 'font/woff2');
const mono = file('node_modules/@fontsource-variable/geist-mono/files/geist-mono-latin-wght-normal.woff2', 'font/woff2');
const appIcon = dataUrl(await sharp(join(here, '..', 'icon.png')).resize(256).png().toBuffer(), 'image/png');
const grain = `data:image/svg+xml;utf8,${encodeURIComponent(
  `<svg xmlns='http://www.w3.org/2000/svg' width='180' height='180'><filter id='n'><feTurbulence type='fractalNoise' baseFrequency='.85' numOctaves='3' stitchTiles='stitch'/><feColorMatrix type='saturate' values='0'/></filter><rect width='100%' height='100%' filter='url(#n)'/></svg>`,
)}`;

// ─── The images ────────────────────────────────────────────────────────────────────────────
setGrain(grain);

const Scaled = ({ s, x, y, children }) => (
  <div style={{ position: 'absolute', left: x, top: y, transform: `scale(${s})`, transformOrigin: 'top left' }}>{children}</div>
);

// Text on the left, a window running off the right edge.
const Feature = ({ w = 1600, h = 900, label, title, sub, children }) => (
  <div className="stage" style={{ width: w, height: h }}>
    <div style={{ position: 'absolute', left: 88, top: 0, bottom: 0, width: 470, display: 'flex', flexDirection: 'column', justifyContent: 'center' }}>
      <p className="label">{label}</p>
      <h1 style={{ fontSize: 62, lineHeight: '66px' }}>{title}</h1>
      <p className="sub" style={{ fontSize: 24, lineHeight: '34px', marginTop: 22 }}>{sub}</p>
    </div>
    {children}
  </div>
);

const images = {
  // README, under the title: the app as it opens, with the mini player and a message arriving.
  hero: {
    size: [1600, 1000], scale: 2, type: 'jpeg',
    node: (
      <div className="stage" style={{ width: 1600, height: 1000 }}>
        <Scaled s={1.12} x={139} y={104}><Window page="Home"><Home /></Window></Scaled>
        <div className="fade" style={{ height: 160 }} />
        <Mini x={1400} y={690} w={150} />
        <Toast x={1094} y={22} icon={appIcon} />
      </div>
    ),
  },
  // GitHub's social preview (Settings › General › Social preview): 1280 × 640, under 1 MB.
  'social-preview': {
    size: [1280, 640], scale: 1, type: 'jpeg',
    node: (
      <div className="stage" style={{ width: 1280, height: 640 }}>
        <div style={{ position: 'absolute', left: 72, top: 60, bottom: 60, width: 520, display: 'flex', flexDirection: 'column' }}>
          <div className="brand"><img src={appIcon} /><span>Matte</span></div>
          <h1 style={{ fontSize: 64, lineHeight: '68px', marginTop: 'auto' }}>Your Instagram, on the big screen</h1>
          <p className="sub" style={{ fontSize: 26, lineHeight: '36px', marginTop: 20 }}>Feed, Reels, stories and DMs in a Mac app that won’t slow your computer down. Free.</p>
          <p className="url" style={{ fontSize: 20, marginTop: 34 }}>matte.subhashh.tech</p>
        </div>
        <Scaled s={0.78} x={640} y={92}><Window page="Home"><Home /></Window></Scaled>
      </div>
    ),
  },
  messages: {
    size: [1600, 900], scale: 2, type: 'jpeg',
    node: (
      <Feature label="Messages" title="Answer DMs without reaching for your phone" sub="Messages pop up on your Mac while you work. Reply with a real keyboard, and send photos and videos straight from your computer.">
        <Scaled s={0.8} x={620} y={138}><Window page="Messages"><Messages /></Window></Scaled>
        <Toast x={1100} y={62} icon={appIcon} name="Theo" text="Can you send me the photos from Saturday?" />
      </Feature>
    ),
  },
  reels: {
    size: [1600, 900], scale: 2, type: 'jpeg',
    node: (
      <Feature label="Reels" title="Reels on a screen big enough to enjoy them" sub="Watch with the comments right beside the video. Go check something else and the reel keeps playing in the corner.">
        <Scaled s={0.8} x={620} y={138}><Window page="Reels"><Reels /></Window></Scaled>
        <Mini x={1446} y={548} w={124} kind="dunes" by="ines.r" byKind="dunes" />
      </Feature>
    ),
  },
  planner: {
    size: [1600, 900], scale: 2, type: 'jpeg',
    node: (
      <Feature label="For business and creator accounts" title="Post on time, even on your busiest days" sub="Line up a month of posts and reels, and Instagram publishes each one on time, even with your Mac closed. Then answer every comment still waiting for you.">
        <Scaled s={0.8} x={620} y={138}><Window page="Planner" manager><Planner /></Window></Scaled>
      </Feature>
    ),
  },
  ghost: {
    size: [1600, 900], scale: 2, type: 'jpeg',
    node: (
      <Feature label="Ghost mode" title="Look without being seen" sub="Check a story or read a message on your own time, without anyone knowing you saw it.">
        <div style={{ position: 'absolute', left: 700, top: 0, bottom: 0, width: 780, display: 'flex', flexDirection: 'column', justifyContent: 'center', gap: 18 }}>
          {[['eyeOff', 'Watch stories without “Seen”', 'Your name stays off the viewer list.'], ['send', 'Read messages without “Seen”', 'Chats stay unread for the sender.'], ['comment', 'Type without “typing…”', 'Nobody sees you writing a reply.']].map(([icon, t, d]) => (
            <div key={t} className="toggle">
              <span style={{ width: 52, height: 52, borderRadius: 14, background: 'rgba(255,255,255,.07)', display: 'grid', placeItems: 'center', flexShrink: 0 }}><Icon name={icon} size={26} sw={1.6} /></span>
              <div style={{ flex: 1 }}><div style={{ fontFamily: 'Display', fontSize: 26, fontWeight: 600, letterSpacing: '-.01em' }}>{t}</div><div style={{ fontFamily: 'Display', fontSize: 19, color: '#9a9aa2', marginTop: 4 }}>{d}</div></div>
              <span className="sw" />
            </div>
          ))}
        </div>
      </Feature>
    ),
  },
};

// Marketing type and the dark stage, after the README images' look.
const css = `
@font-face { font-family: Display; src: url(${sans}) format('woff2'); font-weight: 100 900; }
@font-face { font-family: Mono; src: url(${mono}) format('woff2'); font-weight: 100 900; }
* { box-sizing: border-box; margin: 0; }
html, body { background: transparent; }
body { overflow: hidden; color: #f2f2f4; font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; -webkit-font-smoothing: antialiased; }
i, em { font-style: normal; }
.stage { position: relative; overflow: hidden; background:
  radial-gradient(60% 70% at 78% 40%, rgba(232,51,109,.13), rgba(232,51,109,0) 70%),
  radial-gradient(50% 60% at 95% 90%, rgba(123,92,255,.12), rgba(123,92,255,0) 70%),
  radial-gradient(40% 50% at 10% 0%, rgba(255,255,255,.05), rgba(255,255,255,0) 70%), #0c0c0e; }
.stage::after { content: ''; position: absolute; inset: 0; background-image: url("${grain}"); opacity: .06; mix-blend-mode: overlay; pointer-events: none; }
.brand { display: flex; align-items: center; gap: 14px; }
.brand img { width: 56px; height: 56px; }
.brand span { font-family: 'Snell Roundhand'; font-weight: 900; font-size: 46px; line-height: 1; padding-top: 4px; }
.label { font-family: Display; font-size: 22px; color: #8d8d95; letter-spacing: .01em; margin-bottom: 14px; }
h1 { font-family: Display; font-weight: 500; letter-spacing: -0.035em; color: #f4f2ef; text-wrap: balance; }
.sub { font-family: Display; color: #a3a3ab; text-wrap: balance; }
.url { font-family: Mono; color: #6f6f78; }
.fade { position: absolute; left: 0; right: 0; bottom: 0; background: linear-gradient(rgba(12,12,14,0), #0c0c0e); pointer-events: none; }
.toggle { display: flex; align-items: center; gap: 22px; padding: 22px 26px; border-radius: 20px; background: rgba(255,255,255,.045); box-shadow: inset 0 0 0 1px rgba(255,255,255,.08); }
.sw { width: 52px; height: 32px; border-radius: 16px; background: #f2f2f4; position: relative; flex-shrink: 0; }
.sw::after { content: ''; position: absolute; right: 3px; top: 3px; width: 26px; height: 26px; border-radius: 50%; background: #131315; }
${appCss}
`;

// The website's screenshots: the window (and what floats around it) on a transparent
// background, once per theme. Room is left around the window for its shadow.
const shot = (w, h, node) => ({ size: [w, h], scale: 2, site: true, node });
for (const light of [false, true]) {
  const t = light ? 'light' : 'dark';
  Object.assign(images, {
    [`shots/home-${t}`]: shot(1480, 1100, (
      <div style={{ position: 'relative', width: 1480, height: 1100 }}>
        <div style={{ position: 'absolute', left: 110, top: 96 }}><Window page="Home" light={light}><Home /></Window></div>
        <Toast x={930} y={40} icon={appIcon} light={light} />
        <Mini x={1196} y={600} w={170} light={light} />
      </div>
    )),
    [`shots/messages-${t}`]: shot(1440, 1100, (
      <div style={{ position: 'relative', width: 1440, height: 1100 }}>
        <div style={{ position: 'absolute', left: 130, top: 100 }}><Window page="Messages" light={light}><Messages /></Window></div>
        <Toast x={900} y={44} icon={appIcon} light={light} name="Theo" text="Can you send me the photos from Saturday?" />
      </div>
    )),
    [`shots/reels-${t}`]: shot(1440, 1100, (
      <div style={{ position: 'relative', width: 1440, height: 1100 }}>
        <div style={{ position: 'absolute', left: 130, top: 100 }}><Window page="Reels" light={light}><Reels /></Window></div>
        <Mini x={1210} y={600} w={150} kind="dunes" by="ines.r" byKind="dunes" light={light} />
      </div>
    )),
    [`shots/planner-${t}`]: shot(1440, 1100, (
      <div style={{ position: 'relative', width: 1440, height: 1100 }}>
        <div style={{ position: 'absolute', left: 130, top: 100 }}><Window page="Planner" manager light={light}><Planner /></Window></div>
      </div>
    )),
    [`wordmark-${t}`]: { size: [600, 260], scale: 3, site: true, png: true, node: (
      <div style={{ width: 600, height: 260, display: 'grid', placeItems: 'center', fontFamily: 'Snell Roundhand', fontWeight: 900, fontSize: 150, color: light ? '#1b1815' : '#f4f1ec' }}>Matte</div>
    ) },
  });
}

const only = process.argv.slice(2);
const browser = await chromium.launch();
for (const [name, img] of Object.entries(images)) {
  if (only.length && !only.some((o) => name.startsWith(o))) continue;
  const [width, height] = img.size;
  const page = await browser.newPage({ viewport: { width, height }, deviceScaleFactor: img.scale });
  await page.setContent(`<!doctype html><meta charset="utf-8"><style>${css}</style>${renderToStaticMarkup(img.node)}`, { waitUntil: 'load' });
  await page.evaluate(() => document.fonts.ready);
  let path;
  if (img.site) {
    const png = await page.screenshot({ type: 'png', omitBackground: true });
    path = join(site, `${name}.${img.png ? 'png' : 'webp'}`);
    mkdirSync(dirname(path), { recursive: true });
    if (img.png) await sharp(png).trim().png({ compressionLevel: 9 }).toFile(path);
    else await sharp(png).webp({ quality: 84, alphaQuality: 90, effort: 6 }).toFile(path);
  } else {
    path = join(out, `${name}.${img.type === 'jpeg' ? 'jpg' : 'png'}`);
    await page.screenshot({ path, type: img.type, quality: img.type === 'jpeg' ? 88 : undefined });
  }
  await page.close();
  console.log(path);
}
await browser.close();

// The site's icons and link preview, from the app icon and the README's social preview.
if (!only.length) {
  await sharp(join(here, '..', 'icon.png')).resize(180).png().toFile(join(site, 'apple-touch-icon.png'));
  await sharp(join(here, '..', 'icon.png')).resize(64).png().toFile(join(site, 'favicon.png'));
  await sharp(join(out, 'social-preview.jpg')).toFile(join(site, 'og.jpg'));
}
