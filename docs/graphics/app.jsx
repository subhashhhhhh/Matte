// Matte's windows, drawn in React: used by render.jsx for the README images and the
// website's screenshots. Made-up accounts and generated artwork; nothing real.
// Every colour of the window comes from CSS variables, so `<Window light>` draws the app's
// light mode.
import React from 'react';

// ─── Icons (stroked, 24-unit grid, like the app's) ─────────────────────────────────────────
let grain = '';
/** The film-grain texture (a data URL), set once by the caller. */
export const setGrain = (g) => { grain = g; };

export const I = {
  home: ['M15 21v-8a1 1 0 0 0-1-1h-4a1 1 0 0 0-1 1v8', 'M3 10a2 2 0 0 1 .709-1.528l7-5.999a2 2 0 0 1 2.582 0l7 5.999A2 2 0 0 1 21 10v9a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2z'],
  explore: [['circle', 12, 12, 10], 'm16.24 7.76-1.804 5.411a2 2 0 0 1-1.265 1.265L7.76 16.24l1.804-5.411a2 2 0 0 1 1.265-1.265z'],
  reels: [['rect', 3, 3, 18, 18, 5], 'M3 8.5h18', 'M8.5 3l3 5.5', 'M14.5 3l3 5.5', 'M10 12.2v5.6l4.8-2.8z'],
  send: ['M22 3 9.218 10.083', 'M11.698 20.334 22 3.001H2l7.218 7.083z'],
  create: [['rect', 3, 3, 18, 18, 5], 'M8 12h8', 'M12 8v8'],
  settings: ['M12.22 2h-.44a2 2 0 0 0-2 2v.18a2 2 0 0 1-1 1.73l-.43.25a2 2 0 0 1-2 0l-.15-.08a2 2 0 0 0-2.73.73l-.22.38a2 2 0 0 0 .73 2.73l.15.1a2 2 0 0 1 1 1.72v.51a2 2 0 0 1-1 1.74l-.15.09a2 2 0 0 0-.73 2.73l.22.38a2 2 0 0 0 2.73.73l.15-.08a2 2 0 0 1 2 0l.43.25a2 2 0 0 1 1 1.73V20a2 2 0 0 0 2 2h.44a2 2 0 0 0 2-2v-.18a2 2 0 0 1 1-1.73l.43-.25a2 2 0 0 1 2 0l.15.08a2 2 0 0 0 2.73-.73l.22-.39a2 2 0 0 0-.73-2.73l-.15-.08a2 2 0 0 1-1-1.74v-.5a2 2 0 0 1 1-1.74l.15-.09a2 2 0 0 0 .73-2.73l-.22-.38a2 2 0 0 0-2.73-.73l-.15.08a2 2 0 0 1-2 0l-.43-.25a2 2 0 0 1-1-1.73V4a2 2 0 0 0-2-2z', ['circle', 12, 12, 3]],
  heart: ['M19 14c1.49-1.46 3-3.21 3-5.5A5.5 5.5 0 0 0 16.5 3c-1.76 0-3 .5-4.5 2-1.5-1.5-2.74-2-4.5-2A5.5 5.5 0 0 0 2 8.5c0 2.3 1.5 4.05 3 5.5l7 7Z'],
  comment: ['M20.656 17.008a9.993 9.993 0 1 0-3.59 3.615L22 22Z'],
  repost: ['m17 2 4 4-4 4', 'M3 11v-1a4 4 0 0 1 4-4h14', 'm7 22-4-4 4-4', 'M21 13v1a4 4 0 0 1-4 4H3'],
  bookmark: ['m19 21-7-4-7 4V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2v16z'],
  search: [['circle', 11, 11, 7.5], 'm21 21-4.6-4.6'],
  calendar: [['rect', 3, 4.5, 18, 17, 3], 'M16 2.5v4', 'M8 2.5v4', 'M3 10h18'],
  left: ['m15 18-6-6 6-6'],
  right: ['m9 18 6-6-6-6'],
  up: ['m18 15-6-6-6 6'],
  down: ['m6 9 6 6 6-6'],
  refresh: ['M21 12a9 9 0 1 1-9-9c2.52 0 4.93 1 6.74 2.74L21 8', 'M21 3v5h-5'],
  pin: ['M12 17v5', 'M9 10.76a2 2 0 0 1-1.11 1.79l-1.78.9A2 2 0 0 0 5 15.24V16a1 1 0 0 0 1 1h12a1 1 0 0 0 1-1v-.76a2 2 0 0 0-1.11-1.79l-1.78-.9A2 2 0 0 1 15 10.76V7a1 1 0 0 1 1-1 2 2 0 0 0 0-4H8a2 2 0 0 0 0 4 1 1 0 0 1 1 1z'],
  image: [['rect', 3, 3, 18, 18, 4], ['circle', 9, 9, 2], 'm21 15-3.086-3.086a2 2 0 0 0-2.828 0L6 21'],
  volume: ['M11 4.702a.705.705 0 0 0-1.203-.498L6.413 7.587A1.4 1.4 0 0 1 5.416 8H3a1 1 0 0 0-1 1v6a1 1 0 0 0 1 1h2.416a1.4 1.4 0 0 1 .997.413l3.383 3.384A.705.705 0 0 0 11 19.298z', 'M16 9a5 5 0 0 1 0 6', 'M19.364 18.364a9 9 0 0 0 0-12.728'],
  more: [['circle', 5, 12, 1.2], ['circle', 12, 12, 1.2], ['circle', 19, 12, 1.2]],
  carousel: [['rect', 8, 8, 13, 13, 2.5], 'M4.5 16A2.5 2.5 0 0 1 3 13.5v-8A2.5 2.5 0 0 1 5.5 3h8A2.5 2.5 0 0 1 16 4.5'],
  music: ['M9 18V5l12-2v13', ['circle', 6, 18, 3], ['circle', 18, 16, 3]],
  compose: ['M12 3H5a2 2 0 0 0-2 2v14a2 2 0 0 0 2 2h14a2 2 0 0 0 2-2v-7', 'M18.375 2.625a1 1 0 0 1 3 3l-9.013 9.014a2 2 0 0 1-.853.505l-2.873.84a.5.5 0 0 1-.62-.62l.84-2.873a2 2 0 0 1 .506-.852z'],
  expand: ['M7 7h10v10', 'M7 17 17 7'],
  panel: [['rect', 3, 4, 18, 16, 3], 'M15 4v16'],
  eyeOff: ['M10.733 5.076a10.744 10.744 0 0 1 11.205 6.575 1 1 0 0 1 0 .696 10.747 10.747 0 0 1-1.444 2.49', 'M14.084 14.158a3 3 0 0 1-4.242-4.242', 'M17.479 17.499a10.75 10.75 0 0 1-15.417-5.151 1 1 0 0 1 0-.696 10.75 10.75 0 0 1 4.446-5.143', 'm2 2 20 20'],
  pencil: ['M21.174 6.812a1 1 0 0 0-3.986-3.987L3.842 16.174a2 2 0 0 0-.5.83l-1.321 4.352a.5.5 0 0 0 .623.622l4.353-1.32a2 2 0 0 0 .83-.497z'],
  x: ['M18 6 6 18', 'm6 6 12 12'],
  plus: ['M5 12h14', 'M12 5v14'],
  mic: [['rect', 9, 2, 6, 12, 3], 'M19 10v1a7 7 0 0 1-14 0v-1', 'M12 18v4'],
  clock: [['circle', 12, 12, 9.5], 'M12 7v5l3 2'],
};

export const Icon = ({ name, size = 22, sw = 1.7, fill = 'none', style }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" fill={fill} stroke="currentColor" strokeWidth={sw}
    strokeLinecap="round" strokeLinejoin="round" style={{ display: 'block', flexShrink: 0, ...style }}>
    {I[name].map((p, i) =>
      typeof p === 'string' ? <path key={i} d={p} />
        : p[0] === 'circle' ? <circle key={i} cx={p[1]} cy={p[2]} r={p[3]} />
          : <rect key={i} x={p[1]} y={p[2]} width={p[3]} height={p[4]} rx={p[5]} />)}
  </svg>
);

export const Verified = ({ size = 13 }) => (
  <svg width={size} height={size} viewBox="0 0 24 24" style={{ flexShrink: 0 }}>
    <path fill="#4b9bff" d="M12 1.5l2.6 1.9 3.2-.1 1 3.1 2.6 1.9-1 3.1 1 3.1-2.6 1.9-1 3.1-3.2-.1L12 22.5l-2.6-1.9-3.2.1-1-3.1-2.6-1.9 1-3.1-1-3.1 2.6-1.9 1-3.1 3.2.1z" />
    <path d="m8 12.2 2.6 2.6L16.2 9.2" fill="none" stroke="#fff" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round" />
  </svg>
);

// ─── Artwork: made-up "photos", layered gradients with film grain ───────────────────────────
const S = (style) => <i style={{ position: 'absolute', display: 'block', ...style }} />;
const ART = {
  dusk: () => ({
    bg: 'linear-gradient(180deg,#1c1a3c 0%,#4f3368 32%,#c4605a 64%,#f3b98c 86%,#f8d3ad 100%)',
    shapes: [
      S({ left: '30%', top: '46%', width: '40%', aspectRatio: '1', borderRadius: '50%', background: 'radial-gradient(circle,#fff1d6 0%,#ffc58e 45%,rgba(255,170,120,0) 70%)' }),
      S({ left: '-40%', bottom: '-30%', width: '120%', height: '55%', borderRadius: '50%', background: '#2b1830' }),
      S({ right: '-50%', bottom: '-34%', width: '130%', height: '52%', borderRadius: '50%', background: '#170d1c' }),
    ],
  }),
  ocean: () => ({
    bg: 'linear-gradient(180deg,#bcd6e6 0%,#efe4d4 58%,#2d6d8c 58.4%,#174a63 80%,#0d3247 100%)',
    shapes: [
      S({ left: '58%', top: '30%', width: '16%', aspectRatio: '1', borderRadius: '50%', background: 'radial-gradient(circle,#fff8ea 0%,#ffe6c0 50%,rgba(255,230,192,0) 72%)' }),
      S({ left: '62%', top: '58.4%', width: '8%', height: '30%', background: 'linear-gradient(180deg,rgba(255,240,215,.7),rgba(255,240,215,0))', filter: 'blur(3px)' }),
    ],
  }),
  dunes: () => ({
    bg: 'linear-gradient(180deg,#f7dcb5 0%,#eeb07a 55%,#d98a55 100%)',
    shapes: [
      S({ left: '-30%', top: '48%', width: '110%', height: '70%', borderRadius: '50% 50% 0 0', background: 'linear-gradient(170deg,#d27a43,#a95a2d)' }),
      S({ right: '-40%', top: '60%', width: '120%', height: '70%', borderRadius: '50% 50% 0 0', background: 'linear-gradient(190deg,#b9643a,#7d3f1f)' }),
      S({ left: '-10%', top: '76%', width: '90%', height: '60%', borderRadius: '50% 50% 0 0', background: 'linear-gradient(160deg,#8f4a25,#5a2b14)' }),
    ],
  }),
  forest: () => ({
    bg: 'linear-gradient(180deg,#a9c4b2 0%,#5b8a77 38%,#1f4a40 70%,#0c2420 100%)',
    shapes: [
      ...[0, 11, 22, 33, 44, 55, 66, 77, 88].map((x, i) =>
        S({ left: `${x - 4}%`, bottom: 0, width: '18%', height: `${48 + ((i * 37) % 22)}%`, background: i % 2 ? '#0e2622' : '#143530', clipPath: 'polygon(50% 0,100% 100%,0 100%)' })),
      S({ left: 0, right: 0, top: '42%', height: '22%', background: 'linear-gradient(180deg,rgba(230,240,232,0),rgba(230,240,232,.35),rgba(230,240,232,0))', filter: 'blur(6px)' }),
    ],
  }),
  neon: () => ({
    bg: '#110b24',
    shapes: [
      S({ left: '-10%', top: '8%', width: '70%', height: '60%', borderRadius: '50%', background: '#ff3d8b', filter: 'blur(38px)', opacity: 0.75 }),
      S({ right: '-14%', top: '30%', width: '66%', height: '56%', borderRadius: '50%', background: '#2fd0ff', filter: 'blur(42px)', opacity: 0.6 }),
      S({ left: '20%', bottom: '-12%', width: '60%', height: '40%', borderRadius: '50%', background: '#7b5cff', filter: 'blur(40px)', opacity: 0.8 }),
      ...[[18, 22, 7], [70, 16, 5], [56, 62, 9], [30, 74, 6], [82, 70, 4]].map(([x, y, s], i) =>
        S({ left: `${x}%`, top: `${y}%`, width: `${s}%`, aspectRatio: '1', borderRadius: '50%', background: 'rgba(255,255,255,.55)', filter: 'blur(1.5px)' })),
    ],
  }),
  still: () => ({
    bg: 'linear-gradient(180deg,#ece4d8 0%,#ddd0bf 66%,#bda58b 66.2%,#a98f75 100%)',
    shapes: [
      S({ left: '16%', bottom: '30%', width: '22%', height: '40%', borderRadius: '45% 45% 18% 18% / 30% 30% 12% 12%', background: 'linear-gradient(90deg,#26302c,#3d4a44 60%,#26302c)' }),
      S({ left: '42%', bottom: '30%', width: '17%', height: '26%', borderRadius: '50% 50% 30% 30%', background: 'linear-gradient(90deg,#b75c3d,#d98462 55%,#a44e31)' }),
      S({ left: '62%', bottom: '30%', width: '24%', height: '18%', borderRadius: '50% 50% 40% 40% / 60% 60% 40% 40%', background: 'linear-gradient(90deg,#d9cab3,#f4ead9 55%,#cbb99e)' }),
      S({ left: '10%', bottom: '24%', width: '80%', height: '8%', borderRadius: '50%', background: 'rgba(60,40,25,.25)', filter: 'blur(6px)' }),
    ],
  }),
  peaks: () => ({
    bg: 'linear-gradient(180deg,#9fb9d8 0%,#dfd6cf 52%,#7d93a8 52.2%,#5f7489 100%)',
    shapes: [
      S({ left: '-10%', top: '18%', width: '70%', height: '35%', background: 'linear-gradient(180deg,#eef2f6 0%,#eef2f6 18%,#6b7d96 19%,#4a5a73 100%)', clipPath: 'polygon(50% 0,100% 100%,0 100%)' }),
      S({ left: '34%', top: '8%', width: '80%', height: '45%', background: 'linear-gradient(180deg,#f7f9fb 0%,#f7f9fb 16%,#566985 17%,#35435a 100%)', clipPath: 'polygon(48% 0,100% 100%,0 100%)' }),
      S({ left: 0, right: 0, top: '52.2%', height: '48%', background: 'linear-gradient(180deg,rgba(255,255,255,.18),rgba(0,0,0,.15))' }),
    ],
  }),
  city: () => ({
    bg: 'linear-gradient(180deg,#25304d 0%,#6b4f6e 45%,#d88a69 75%,#f0b58a 100%)',
    shapes: [[0, 46, 14], [12, 30, 12], [23, 52, 10], [32, 22, 13], [44, 40, 9], [52, 14, 12], [63, 36, 11], [73, 26, 14], [86, 44, 15]].map(([x, top, w], i) =>
      S({ left: `${x}%`, top: `${top + 20}%`, width: `${w}%`, bottom: 0, background: i % 2 ? '#141824' : '#1b2131',
        backgroundImage: 'radial-gradient(rgba(255,214,150,.7) 0.9px,transparent 1.2px)', backgroundSize: '7px 9px' })),
  }),
  bloom: () => ({
    bg: 'radial-gradient(120% 90% at 30% 20%,#f6cbb8 0%,#e48d86 40%,#a6476a 75%,#5b2347 100%)',
    shapes: [
      S({ left: '40%', top: '30%', width: '50%', aspectRatio: '1', borderRadius: '50%', background: 'radial-gradient(circle,#ffe7d6,#f7a59a 55%,rgba(247,165,154,0) 72%)', filter: 'blur(4px)' }),
      S({ left: '-6%', top: '56%', width: '44%', aspectRatio: '1', borderRadius: '50%', background: 'radial-gradient(circle,#ffd3a8,rgba(255,211,168,0) 70%)', filter: 'blur(8px)' }),
    ],
  }),
  concrete: () => ({
    bg: 'linear-gradient(180deg,#e4e2df,#cfccc7)',
    shapes: [
      S({ left: '-20%', top: '-10%', width: '80%', height: '130%', transform: 'skewX(-24deg)', background: 'linear-gradient(90deg,rgba(40,38,36,.55),rgba(40,38,36,.25))' }),
      S({ left: '62%', top: '-10%', width: '14%', height: '130%', transform: 'skewX(-24deg)', background: 'rgba(40,38,36,.32)' }),
      S({ left: '8%', top: '58%', width: '18%', height: '26%', borderRadius: 2, background: '#b34a2f' }),
    ],
  }),
  tide: () => ({
    bg: 'linear-gradient(200deg,#0f3a4d 0%,#1c6a7c 40%,#58a6a2 70%,#d9ccb0 100%)',
    shapes: [0, 1, 2, 3].map((i) =>
      S({ left: '-20%', top: `${54 + i * 11}%`, width: '140%', height: '16%', borderRadius: '50%', border: '2px solid rgba(255,255,255,.35)', borderBottom: 'none', borderLeft: 'none', borderRight: 'none' })),
  }),
  noir: () => ({
    bg: 'radial-gradient(70% 60% at 50% 35%,#4a4a52 0%,#1d1d22 70%,#0d0d10 100%)',
    shapes: [
      S({ left: '32%', top: '22%', width: '36%', height: '38%', borderRadius: '50% 50% 46% 46%', background: 'linear-gradient(110deg,#d9d6d0,#7d7a76 70%)' }),
      S({ left: '18%', top: '58%', width: '64%', height: '60%', borderRadius: '45% 45% 0 0', background: 'linear-gradient(110deg,#33333a,#16161a)' }),
    ],
  }),
};

export const Art = ({ kind, style, radius = 0, children }) => {
  const a = ART[kind]();
  return (
    <div style={{ position: 'relative', overflow: 'hidden', background: a.bg, borderRadius: radius, ...style }}>
      {a.shapes.map((s, i) => React.cloneElement(s, { key: i }))}
      <i style={{ position: 'absolute', inset: 0, backgroundImage: `url("${grain}")`, opacity: 0.22, mixBlendMode: 'overlay' }} />
      {children}
    </div>
  );
};

export const Avatar = ({ kind, size, ring = false, style }) =>
  ring ? (
    <div style={{ width: size, height: size, borderRadius: '50%', padding: 2.5, flexShrink: 0, background: 'conic-gradient(from 200deg,#f9a03f,#e8336d,#b836c9,#f9a03f)', ...style }}>
      <div style={{ width: '100%', height: '100%', borderRadius: '50%', padding: 2.5, background: 'var(--wbg)' }}>
        <Art kind={kind} radius="50%" style={{ width: '100%', height: '100%' }} />
      </div>
    </div>
  ) : (
    <Art kind={kind} radius="50%" style={{ width: size, height: size, flexShrink: 0, ...style }} />
  );

// ─── The app window ─────────────────────────────────────────────────────────────────────────
const NAV = [
  ['home', 'Home'], ['explore', 'Explore'], ['reels', 'Reels'], ['send', 'Messages'],
];
const MANAGER = [['calendar', 'Planner'], ['comment', 'Replies']];

export const Window = ({ page, manager = false, light = false, children }) => (
  <div className={`mt win ${light ? 'light' : ''}`}>
    <div className="rail">
      <div className="lights"><i style={{ background: '#ff5f57' }} /><i style={{ background: '#febc2e' }} /><i style={{ background: '#28c840' }} /></div>
      {[...NAV, ...(manager ? MANAGER : [])].map(([icon, label]) => (
        <div key={label} className={`nav ${page === label ? 'on' : ''}`}>
          <Icon name={icon} size={23} sw={page === label ? 2.1 : 1.6} />
          <span>{label}</span>
          {label === 'Messages' && <b className="badge">2</b>}
        </div>
      ))}
      <div className="sep" />
      <div className="nav"><Icon name="create" size={23} sw={1.6} /><span>Create</span></div>
      <div className="foot">
        <div className="nav"><Icon name="settings" size={21} sw={1.5} /><span>Settings</span></div>
        <Avatar kind="bloom" size={32} style={{ margin: '10px auto 0' }} />
      </div>
    </div>
    <div className="top">
      <span className="mark">Matte</span>
      <div className="search"><Icon name="search" size={17} sw={1.8} /><span>Search</span></div>
      <Icon name="heart" size={23} sw={1.6} style={{ marginLeft: 'auto', marginRight: 22 }} />
    </div>
    <div className="content">{children}</div>
  </div>
);

// ─── Pages ──────────────────────────────────────────────────────────────────────────────────
const POSTS = [
  { user: 'studio.alma', art: 'still', avatar: 'still', time: '9m', likes: '1.3K', comments: 48, reposts: 12, count: 4, ratio: 1.25,
    caption: 'New glazes out of the kiln this morning. The terracotta one is going home with me.' },
  { user: 'northlight', art: 'peaks', avatar: 'peaks', time: '24m', likes: '8.9K', comments: 211, reposts: 64, music: 'Low Tide · Haru Mori', ratio: 1.25,
    caption: 'Four days on the ridge, one clear morning. Worth every switchback.' },
  { user: 'kiko.films', art: 'dusk', avatar: 'dusk', time: '1h', likes: '2.4K', comments: 57, reposts: 19, count: 7, ratio: 1.25,
    caption: 'Last light over the bay, shot on expired film.' },
  { user: 'maison.ode', art: 'concrete', avatar: 'concrete', time: '3h', likes: '612', comments: 23, reposts: 4, ratio: 1 },
  { user: 'saltwater.co', art: 'ocean', avatar: 'tide', time: '5h', likes: '5.1K', comments: 98, reposts: 31, ratio: 1 },
  { user: 'aurelia.m', art: 'city', avatar: 'bloom', time: '6h', likes: '940', comments: 12, reposts: 2, ratio: 1 },
];

const Post = ({ p }) => (
  <div className="post">
    <div className="ph">
      <Avatar kind={p.avatar} size={26} />
      <div style={{ minWidth: 0 }}>
        <div className="pn">{p.user} <Verified /></div>
        {p.music && <div className="pm"><Icon name="music" size={11} sw={2} /> {p.music}</div>}
      </div>
      <span className="pt">{p.time}</span>
    </div>
    <Art kind={p.art} radius={10} style={{ width: '100%', aspectRatio: `1 / ${p.ratio}` }}>
      {p.count && <span className="chip"><Icon name="carousel" size={12} sw={2.2} /> {p.count}</span>}
      {p.count && <div className="dots">{Array.from({ length: p.count }, (_, i) => <i key={i} style={{ opacity: i ? 0.45 : 1 }} />)}</div>}
    </Art>
    <div className="acts">
      <span><Icon name="heart" size={19} />{p.likes}</span>
      <span><Icon name="comment" size={19} />{p.comments}</span>
      <span><Icon name="repost" size={19} />{p.reposts}</span>
      <Icon name="send" size={19} />
      <Icon name="bookmark" size={19} style={{ marginLeft: 'auto' }} />
    </div>
    {p.caption && <p className="cap">{p.caption}</p>}
  </div>
);

export const Home = () => (
  <div style={{ display: 'flex', height: '100%' }}>
    <div className="stories">
      {['bloom', 'peaks', 'still', 'neon', 'ocean', 'forest', 'dunes', 'city', 'tide', 'noir', 'concrete'].map((k, i) =>
        <Avatar key={k} kind={k} size={52} ring={i > 0} />)}
    </div>
    <div style={{ flex: 1, padding: '16px 24px 0 26px', overflow: 'hidden' }}>
      <div className="seg"><span className="on">For you</span><span>Following</span><span>Favorites</span></div>
      <div className="cols">
        {[0, 1, 2].map((c) => (
          <div key={c} className="col">
            <Post p={POSTS[c]} />
            <Post p={POSTS[c + 3]} />
          </div>
        ))}
      </div>
    </div>
  </div>
);

const CHATS = [
  { name: 'Maya Lindqvist', art: 'bloom', last: 'Typing…', time: '', typing: true, pinned: true },
  { name: 'Studio Alma', art: 'still', last: 'You: Sending the edits tonight', time: '12m', verified: true },
  { name: 'Theo', art: 'peaks', last: 'Voice message', time: '1h', unread: true },
  { name: 'Weekend crew', art: 'dunes', last: 'Ines: who’s driving?', time: '3h' },
  { name: 'Kiko', art: 'neon', last: 'Reacted ❤️ to your message', time: '1d' },
  { name: 'Saltwater Co.', art: 'tide', last: 'You: Perfect, thank you!', time: '2d', verified: true },
];

export const Messages = () => (
  <div style={{ display: 'flex', height: '100%' }}>
    <div className="inbox">
      <div className="ih"><h2>Messages</h2><Icon name="refresh" size={18} /><Icon name="compose" size={18} /></div>
      <div className="seg wide"><span className="on">Chats</span><span>Requests</span></div>
      {CHATS.map((c, i) => (
        <div key={c.name} className={`chat ${i === 0 ? 'on' : ''}`}>
          <Avatar kind={c.art} size={46} />
          <div style={{ minWidth: 0, flex: 1 }}>
            <div className="cn">{c.name} {c.verified && <Verified />}</div>
            <div className={`cl ${c.unread ? 'b' : ''}`}>{c.typing ? <em>Typing…</em> : c.last}{c.time && ` · ${c.time}`}</div>
          </div>
          {c.pinned && <Icon name="pin" size={14} style={{ opacity: 0.6 }} />}
          {c.unread && <i className="dot" />}
        </div>
      ))}
    </div>
    <div className="thread">
      <div className="th">
        <Avatar kind="bloom" size={36} />
        <div><div className="cn">Maya Lindqvist</div><div className="cl">Active now</div></div>
        <div style={{ marginLeft: 'auto', display: 'flex', gap: 20, opacity: 0.85 }}><Icon name="expand" size={19} /><Icon name="panel" size={19} /><Icon name="more" size={19} /></div>
      </div>
      <div className="msgs">
        <div className="when">Today 9:41</div>
        <div className="row in"><div className="bub">Are we still on for the shoot tomorrow?</div></div>
        <div className="row in"><div className="bub">I found a spot by the water, the light there at 6 is unreal</div></div>
        <div className="row out"><div className="bub me">Yes! I’ll bring the 35mm and the reflector</div></div>
        <div className="row in">
          <div className="share">
            <div className="sh"><Avatar kind="tide" size={20} /> saltwater.co</div>
            <Art kind="ocean" style={{ width: 200, height: 220 }}><span className="chip"><Icon name="reels" size={12} sw={2} /></span></Art>
          </div>
        </div>
        <div className="row in"><div className="bub">this spot 👆</div></div>
        <div className="row out" style={{ position: 'relative' }}>
          <div className="voice me"><span className="play"><svg width="11" height="12" viewBox="0 0 11 12"><path d="M1 1l9 5-9 5z" fill="currentColor" /></svg></span>
            <div className="wave">{[6, 12, 18, 9, 14, 22, 16, 8, 12, 20, 15, 7, 11, 17, 21, 10, 6, 13, 18, 9, 5, 12, 8].map((h, i) => <i key={i} style={{ height: h, opacity: i < 9 ? 1 : 0.5 }} />)}</div>
            <span className="vt">0:12</span></div>
          <span className="react">❤️</span>
        </div>
        <div className="seen">Seen</div>
        <div className="row in"><div className="typing"><i /><i /><i /></div></div>
      </div>
      <div className="composer"><Icon name="image" size={20} /><span>Message…</span><Icon name="mic" size={19} style={{ marginLeft: 'auto' }} /></div>
    </div>
  </div>
);

export const Reels = () => (
  <div style={{ display: 'flex', height: '100%', paddingTop: 20 }}>
    <div className="rthumbs">
      {['neon', 'dunes', 'forest', 'city', 'tide'].map((k, i) => <Art key={k} kind={k} radius={8} style={{ width: 84, height: 148, outline: i === 0 ? '2px solid var(--ink)' : 'none', outlineOffset: 1 }} />)}
    </div>
    <Art kind="neon" radius={14} style={{ width: 384, height: 683, marginLeft: 26, flexShrink: 0 }}>
      <span className="vol"><Icon name="volume" size={16} sw={2} /></span>
      <div className="rby"><Avatar kind="dusk" size={30} /> kiko.films</div>
      <div className="rbar"><b /></div>
    </Art>
    <div className="racts">
      {[['heart', '24.6K'], ['comment', '318'], ['repost', '1.2K'], ['send', ''], ['bookmark', '']].map(([n, v]) =>
        <div key={n}><Icon name={n} size={27} sw={1.6} />{v && <span>{v}</span>}</div>)}
      <Icon name="more" size={22} />
    </div>
    <div className="rpanel">
      <div className="ph" style={{ padding: 0 }}><Avatar kind="dusk" size={34} /><div><div className="pn">kiko.films <Verified /></div><div className="pm">2 Nov</div></div></div>
      <p className="cap" style={{ fontSize: 14, margin: '14px 0 12px', WebkitLineClamp: 'unset' }}>Night swim in the city, lit by the signs across the river. <span style={{ color: 'var(--link)' }}>#nightphotography #filmlook</span></p>
      <div className="acts" style={{ padding: '4px 0 14px', borderBottom: '1px solid var(--line)' }}>
        <span><Icon name="heart" size={21} />24.6K</span><span><Icon name="comment" size={21} />318</span><span><Icon name="repost" size={21} />1.2K</span><Icon name="send" size={21} /><Icon name="bookmark" size={21} style={{ marginLeft: 'auto' }} />
      </div>
      {[['bloom', 'maya.lq', 'the colours on this 😮‍💨', '412 likes'], ['peaks', 'northlight', 'what film stock is this?', '128 likes'], ['still', 'studio.alma', 'Framing this one.', '96 likes'], ['dunes', 'ines.r', 'Need the full series', '40 likes'], ['tide', 'saltwater.co', '🌊🌊🌊', '12 likes']].map(([k, u, t, l]) => (
        <div key={u} className="cm"><Avatar kind={k} size={30} /><div style={{ flex: 1 }}><div className="pn" style={{ fontSize: 13 }}>{u} <span className="pt" style={{ marginLeft: 6 }}>2 Nov</span></div><div className="ct">{t}</div><div className="pt">{l} · Reply</div></div><Icon name="heart" size={14} style={{ opacity: 0.6 }} /></div>
      ))}
      <div className="addc">Add a comment…</div>
    </div>
  </div>
);

// Scheduled posts on the planner: [day, time, art, kind].
const PLANNED = { 16: [['9:00', 'still', 'Post']], 18: [['12:30', 'neon', 'Reel']], 19: [['18:00', 'peaks', 'Post']], 21: [['10:00', 'bloom', 'Post'], ['19:30', 'dusk', 'Reel']], 24: [['9:00', 'concrete', 'Post']], 26: [['17:45', 'tide', 'Reel']], 28: [['11:00', 'dunes', 'Post']] };
export const Planner = () => {
  const days = [...Array.from({ length: 30 }, (_, i) => i + 1), 1, 2, 3, 4, 5];
  return (
    <div style={{ display: 'flex', height: '100%' }}>
      <div style={{ flex: 1, padding: '22px 24px 0 24px' }}>
        <div className="calh"><h2>November 2026</h2><span className="pill">Today</span><Icon name="left" size={18} /><Icon name="right" size={18} /><Icon name="refresh" size={17} /><span className="pill solid">Schedule Post</span></div>
        <div className="wk">{['SUN', 'MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT'].map((d) => <span key={d}>{d}</span>)}</div>
        <div className="grid">
          {days.map((d, i) => (
            <div key={i} className={`day ${i >= 30 ? 'off' : ''}`}>
              <span className={`dn ${i === 12 ? 'today' : ''}`}>{d}</span>
              {i < 30 && (PLANNED[d] || []).map(([t, k, kind]) => (
                <div key={t} className="evt"><Art kind={k} radius={4} style={{ width: 20, height: 20 }} /><span>{t}</span><em>{kind}</em></div>
              ))}
            </div>
          ))}
        </div>
      </div>
      <div className="upcoming">
        <h3>Upcoming</h3>
        {[['16', 'Mon 16 Nov, 9:00', 'still', 'Post', 'New glazes, first look'], ['18', 'Wed 18 Nov, 12:30', 'neon', 'Reel', 'Night swim, part two'], ['19', 'Thu 19 Nov, 18:00', 'peaks', 'Post', 'The ridge, in four frames'], ['21', 'Sat 21 Nov, 10:00', 'bloom', 'Post', 'Studio open day'], ['21b', 'Sat 21 Nov, 19:30', 'dusk', 'Reel', 'Golden hour, slowed down']].map(([id, when, k, kind, cap], i) => (
          <div key={id} className={`up ${i === 1 ? 'hov' : ''}`}>
            <Art kind={k} radius={8} style={{ width: 52, height: 52 }} />
            <div style={{ flex: 1, minWidth: 0 }}><div className="uw">{when}</div><div className="uc">{cap}</div><div className="uk"><Icon name={kind === 'Reel' ? 'reels' : 'image'} size={12} sw={2} /> {kind}</div></div>
            {i === 1 && <div style={{ display: 'flex', gap: 6 }}><span className="ib"><Icon name="pencil" size={14} /></span><span className="ib"><Icon name="x" size={14} /></span></div>}
          </div>
        ))}
      </div>
    </div>
  );
};

// ─── Floating pieces (outside the window) ───────────────────────────────────────────────────
export const Mini = ({ x, y, w = 168, kind = 'dusk', by = 'kiko.films', byKind = 'dusk', light = false }) => (
  <div className={`mt mini ${light ? 'light' : ''}`} style={{ left: x, top: y, width: w, height: w * 16 / 9 }}>
    <Art kind={kind} style={{ width: '100%', height: '100%' }}>
      <div className="rby" style={{ fontSize: 12, bottom: 16, left: 10 }}><Avatar kind={byKind} size={22} /> {by}</div>
      <div className="rbar"><b style={{ width: '58%' }} /></div>
    </Art>
  </div>
);

export const Toast = ({ x, y, icon, light = false, name = 'Maya Lindqvist', text = 'The light at 6 is unreal, don’t be late 🌅' }) => (
  <div className={`mt toast ${light ? 'light' : ''}`} style={{ left: x, top: y }}>
    <img src={icon} style={{ width: 38, height: 38 }} />
    <div><div style={{ fontSize: 14, fontWeight: 600 }}>{name}</div><div className="tt">{text}</div></div>
  </div>
);

// ─── Styles ────────────────────────────────────────────────────────────────────────────────
// The window's colours: the app's dark and light themes (Views/Theme.swift).
export const appCss = `
.mt { --wbg: #131315; --rail: #1a1a1c; --ink: #f2f2f4; --ink-2: #a0a0a6; --ink-3: #8e8e94; --ink-nav: #c9c9ce; --cap: #dedee2;
  --f1: rgba(255,255,255,.04); --f2: rgba(255,255,255,.055); --f3: rgba(255,255,255,.085); --f4: rgba(255,255,255,.1);
  --line: rgba(255,255,255,.07); --stroke: rgba(255,255,255,.06); --solid: #f2f2f4; --on-solid: #131315; --link: #6cb9ff; --unread: #8fc6ff;
  --frame: 0 0 0 1px rgba(255,255,255,.11), 0 1px 0 0 rgba(255,255,255,.08) inset, 0 50px 120px rgba(0,0,0,.65), 0 20px 40px rgba(0,0,0,.4);
  --float: 0 0 0 1px rgba(255,255,255,.12), 0 24px 50px rgba(0,0,0,.55); --toast: rgba(36,36,40,.92); --react: #2a2a2d;
  color: var(--ink); font-family: -apple-system, BlinkMacSystemFont, 'SF Pro Text', sans-serif; -webkit-font-smoothing: antialiased; }
.mt.light { --wbg: #fcfcfd; --rail: #f2f2f4; --ink: #111113; --ink-2: #5f5f66; --ink-3: #85858c; --ink-nav: #3a3a40; --cap: #2a2a2e;
  --f1: rgba(0,0,0,.03); --f2: rgba(0,0,0,.05); --f3: rgba(0,0,0,.07); --f4: rgba(0,0,0,.085);
  --line: rgba(0,0,0,.08); --stroke: rgba(0,0,0,.07); --solid: #131315; --on-solid: #fcfcfd; --link: #0d73d1; --unread: #0d73d1;
  --frame: 0 0 0 1px rgba(40,30,20,.12), 0 40px 90px rgba(70,50,30,.2), 0 14px 30px rgba(70,50,30,.1);
  --float: 0 0 0 1px rgba(40,30,20,.1), 0 24px 50px rgba(70,50,30,.2); --toast: rgba(250,248,245,.92); --react: #ececee; }
.mt *, .mt { box-sizing: border-box; }
.mt i, .mt em { font-style: normal; }
.mt p, .mt h2, .mt h3 { margin: 0; }

/* The window (1180 × 780, as the app opens) */
.win { position: relative; width: 1180px; height: 780px; border-radius: 13px; background: var(--wbg); overflow: hidden; box-shadow: var(--frame); text-align: left; }
.rail { position: absolute; left: 8px; top: 8px; bottom: 8px; width: 80px; border-radius: 16px; background: var(--rail); display: flex; flex-direction: column; align-items: center; }
.lights { display: flex; gap: 8px; padding: 10px 0 0; margin-bottom: 25px; }
.lights i { display: block; width: 13px; height: 13px; border-radius: 50%; box-shadow: inset 0 0 0 .5px rgba(0,0,0,.25); }
.nav { position: relative; width: 64px; height: 54px; margin-bottom: 2px; border-radius: 12px; display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 3px; color: var(--ink-nav); }
.nav span { font-size: 10.5px; font-weight: 500; letter-spacing: .01em; }
.nav.on { background: var(--f3); color: var(--ink); }
.nav.on span { font-weight: 600; }
.badge { position: absolute; top: 3px; right: 9px; min-width: 16px; height: 16px; border-radius: 8px; background: #ff4f6d; color: #fff; font-size: 10px; font-weight: 700; display: grid; place-items: center; padding: 0 4px; font-style: normal; }
.sep { width: 32px; height: 1px; background: var(--line); margin: 6px 0 8px; }
.foot { margin-top: auto; padding-bottom: 14px; display: flex; flex-direction: column; align-items: center; }
.top { position: absolute; left: 88px; right: 0; top: 0; height: 56px; display: flex; align-items: center; border-bottom: 1px solid var(--line); }
.mark { font-family: 'Snell Roundhand'; font-weight: 900; font-size: 30px; margin-left: 16px; padding-top: 3px; }
.search { position: absolute; left: 360px; width: 420px; height: 34px; border-radius: 10px; background: var(--f2); display: flex; align-items: center; gap: 9px; padding: 0 12px; color: var(--ink-3); font-size: 14px; }
.content { position: absolute; left: 88px; right: 0; top: 56px; bottom: 0; overflow: hidden; }

/* Home */
.stories { width: 76px; padding-top: 16px; border-right: 1px solid var(--line); display: flex; flex-direction: column; align-items: center; gap: 10px; flex-shrink: 0; }
.seg { display: inline-flex; padding: 3px; border-radius: 11px; background: var(--f2); font-size: 13.5px; font-weight: 500; color: var(--ink-2); }
.seg span { padding: 6px 13px; border-radius: 8px; }
.seg .on { background: var(--f4); color: var(--ink); font-weight: 600; }
.mt.light .seg .on { background: #fff; box-shadow: 0 1px 3px rgba(0,0,0,.08); }
.seg.wide { display: flex; margin: 0 4px 10px; }
.seg.wide span { flex: 1; text-align: center; }
.cols { display: flex; gap: 17px; margin-top: 18px; }
.col { flex: 1; display: flex; flex-direction: column; gap: 17px; min-width: 0; }
.post { border-radius: 14px; background: var(--f1); box-shadow: inset 0 0 0 1px var(--stroke); padding: 0 10px 12px; }
.ph { display: flex; align-items: center; gap: 9px; padding: 11px 2px 10px; }
.pn { display: flex; align-items: center; gap: 4px; font-size: 13.5px; font-weight: 600; white-space: nowrap; }
.pm { display: flex; align-items: center; gap: 5px; font-size: 12px; color: var(--ink-2); margin-top: 2px; }
.pt { font-size: 12px; color: var(--ink-3); margin-left: auto; }
.chip { position: absolute; top: 10px; right: 10px; display: flex; align-items: center; gap: 4px; padding: 3px 7px; border-radius: 8px; background: rgba(0,0,0,.45); font-size: 11px; font-weight: 600; color: #fff; }
.dots { position: absolute; left: 0; right: 0; bottom: 10px; display: flex; justify-content: center; gap: 4px; }
.dots i { display: block; width: 5px; height: 5px; border-radius: 50%; background: #fff; }
.acts { display: flex; align-items: center; gap: 15px; padding: 11px 2px 6px; font-size: 13px; font-weight: 500; }
.acts span { display: flex; align-items: center; gap: 6px; }
.cap { font-size: 13px; line-height: 17px; color: var(--cap); padding: 0 2px; display: -webkit-box; -webkit-line-clamp: 2; -webkit-box-orient: vertical; overflow: hidden; }

/* Messages */
.inbox { width: 290px; border-right: 1px solid var(--line); padding: 16px 8px 0; flex-shrink: 0; }
.ih { display: flex; align-items: center; gap: 20px; padding: 0 12px 14px; color: var(--ink-nav); }
.ih h2 { font-size: 21px; font-weight: 700; color: var(--ink); margin-right: auto; }
.chat { display: flex; align-items: center; gap: 12px; padding: 10px 10px; border-radius: 12px; margin-bottom: 2px; }
.chat.on { background: var(--f3); }
.cn { display: flex; align-items: center; gap: 5px; font-size: 14px; font-weight: 600; white-space: nowrap; }
.cl { font-size: 12.5px; color: var(--ink-2); margin-top: 2px; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.cl.b { color: var(--ink); font-weight: 600; }
.cl em { color: var(--unread); }
.dot { width: 8px; height: 8px; border-radius: 50%; background: #4b9bff; flex-shrink: 0; }
.thread { flex: 1; display: flex; flex-direction: column; min-width: 0; }
.th { display: flex; align-items: center; gap: 11px; padding: 12px 20px; border-bottom: 1px solid var(--line); }
.msgs { flex: 1; padding: 14px 22px; display: flex; flex-direction: column; gap: 5px; justify-content: flex-end; }
.when { text-align: center; font-size: 11.5px; color: var(--ink-3); font-weight: 500; margin-bottom: 8px; }
.row { display: flex; }
.row.out { justify-content: flex-end; }
.bub { max-width: 340px; padding: 8px 13px; border-radius: 18px; background: var(--f4); font-size: 14px; line-height: 19px; }
.mt.light .bub { background: #ececee; }
.bub.me, .mt.light .bub.me { background: var(--solid); color: var(--on-solid); }
.share { width: 200px; border-radius: 16px; overflow: hidden; background: var(--f3); margin: 4px 0; }
.sh { display: flex; align-items: center; gap: 7px; padding: 8px 10px; font-size: 12.5px; font-weight: 600; }
.voice { display: flex; align-items: center; gap: 10px; padding: 7px 14px 7px 7px; border-radius: 20px; background: var(--solid); color: var(--on-solid); }
.play { width: 26px; height: 26px; border-radius: 50%; background: rgba(128,128,128,.18); display: grid; place-items: center; padding-left: 2px; }
.wave { display: flex; align-items: center; gap: 2.5px; height: 24px; }
.wave i { display: block; width: 2.5px; border-radius: 2px; background: currentColor; }
.vt { font-size: 12px; font-weight: 600; font-variant-numeric: tabular-nums; }
.react { position: absolute; right: 8px; bottom: -12px; font-size: 13px; background: var(--react); border-radius: 12px; padding: 1px 5px; box-shadow: 0 0 0 2px var(--wbg); }
.seen { text-align: right; font-size: 11.5px; color: var(--ink-3); margin: 12px 4px 4px; }
.typing { display: flex; gap: 4px; padding: 12px 14px; border-radius: 18px; background: var(--f4); }
.mt.light .typing { background: #ececee; }
.typing i { display: block; width: 7px; height: 7px; border-radius: 50%; background: var(--ink-3); }
.typing i:nth-child(2) { opacity: .7; } .typing i:nth-child(3) { opacity: .45; }
.composer { margin: 4px 16px 16px; height: 40px; border-radius: 20px; box-shadow: inset 0 0 0 1px var(--line); display: flex; align-items: center; gap: 12px; padding: 0 14px; color: var(--ink-3); font-size: 14px; }

/* Reels */
.rthumbs { width: 132px; display: flex; flex-direction: column; align-items: flex-end; gap: 10px; flex-shrink: 0; }
.vol { position: absolute; top: 12px; right: 12px; width: 30px; height: 30px; border-radius: 50%; background: rgba(0,0,0,.45); color: #fff; display: grid; place-items: center; }
.rby { position: absolute; left: 14px; bottom: 22px; display: flex; align-items: center; gap: 9px; font-size: 14px; font-weight: 600; color: #fff; text-shadow: 0 1px 6px rgba(0,0,0,.5); }
.rbar { position: absolute; left: 0; right: 0; bottom: 0; height: 3px; background: rgba(255,255,255,.25); }
.rbar b { display: block; width: 34%; height: 100%; background: #fff; }
.racts { width: 70px; display: flex; flex-direction: column; align-items: center; justify-content: flex-end; gap: 22px; padding-bottom: 60px; }
.racts div { display: flex; flex-direction: column; align-items: center; gap: 4px; font-size: 12px; font-weight: 600; }
.rpanel { flex: 1; margin: 0 22px 20px 10px; height: 683px; border-radius: 16px; background: var(--f1); box-shadow: inset 0 0 0 1px var(--line); padding: 18px 18px; position: relative; overflow: hidden; }
.cm { display: flex; gap: 11px; padding: 10px 0; }
.ct { font-size: 13.5px; margin: 3px 0; }
.addc { position: absolute; left: 0; right: 0; bottom: 0; padding: 14px 18px; border-top: 1px solid var(--line); color: var(--ink-3); font-size: 14px; background: var(--wbg); }

/* Planner */
.calh { display: flex; align-items: center; gap: 22px; margin-bottom: 18px; color: var(--ink-nav); }
.calh h2 { font-size: 24px; font-weight: 700; letter-spacing: -.01em; color: var(--ink); margin-right: auto; }
.pill { padding: 7px 14px; border-radius: 16px; background: var(--f3); font-size: 13.5px; font-weight: 600; color: var(--ink); }
.pill.solid { background: var(--solid); color: var(--on-solid); }
.wk { display: grid; grid-template-columns: repeat(7, 1fr); gap: 7px; font-size: 11px; font-weight: 600; letter-spacing: .06em; color: var(--ink-3); margin-bottom: 8px; padding-left: 8px; }
.grid { display: grid; grid-template-columns: repeat(7, 1fr); gap: 7px; }
.day { height: 118px; border-radius: 10px; background: var(--f2); padding: 8px; display: flex; flex-direction: column; gap: 5px; }
.mt.light .day { background: rgba(0,0,0,.035); }
.day.off { background: var(--f1); color: var(--ink-3); }
.dn { font-size: 13px; font-weight: 600; width: 24px; height: 24px; display: grid; place-items: center; border-radius: 50%; margin: -2px 0 0 -2px; }
.dn.today { background: var(--solid); color: var(--on-solid); }
.evt { display: flex; align-items: center; gap: 6px; padding: 3px; border-radius: 7px; background: var(--f3); font-size: 11.5px; font-weight: 600; }
.mt.light .evt { background: #fff; box-shadow: 0 1px 2px rgba(0,0,0,.08); }
.evt em { margin-left: auto; margin-right: 3px; font-size: 10px; color: var(--ink-2); font-weight: 500; }
.upcoming { width: 300px; border-left: 1px solid var(--line); padding: 18px 12px 0; flex-shrink: 0; }
.upcoming h3 { font-size: 17px; font-weight: 700; padding: 0 8px 14px; }
.up { display: flex; align-items: center; gap: 12px; padding: 9px 8px; border-radius: 12px; }
.up.hov { background: var(--f3); }
.uw { font-size: 12px; color: var(--ink-2); font-weight: 500; }
.uc { font-size: 13.5px; font-weight: 600; margin: 2px 0; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
.uk { display: flex; align-items: center; gap: 5px; font-size: 11.5px; color: var(--ink-3); }
.ib { width: 26px; height: 26px; border-radius: 50%; background: var(--f4); display: grid; place-items: center; }

/* Floating pieces */
.mini { position: absolute; border-radius: 14px; overflow: hidden; box-shadow: var(--float); }
.toast { position: absolute; display: flex; align-items: center; gap: 12px; padding: 12px 16px 12px 12px; border-radius: 16px; background: var(--toast); box-shadow: var(--float); backdrop-filter: blur(20px); white-space: nowrap; }
.toast .tt { font-size: 13.5px; color: var(--ink-2); margin-top: 2px; }
`;
