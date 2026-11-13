import fs from 'node:fs';
import path from 'node:path';

// The released version comes from the manifest the in-app updater reads (updates/latest.json).
// scripts/release.sh writes it only after the GitHub release is published, and Cloudflare
// rebuilds the site on that push, so the version and the download links follow each release
// with no change to the site, and never point at a release that isn't out yet.
const manifest = JSON.parse(fs.readFileSync(path.resolve(process.cwd(), '../updates/latest.json'), 'utf8')) as {
  version: string;
  tag: string;
  archives: Record<string, { size: number }>;
};

const parts = (v: string) => v.split('.').map(Number);
export const compareVersions = (a: string, b: string) => {
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d) return d;
  }
  return 0;
};

export const version = manifest.version;

// Each release's notes are docs/releases/<version>.md. Notes are committed before their release
// is published, so only versions up to the released one are listed.
const notesDir = path.resolve(process.cwd(), '../docs/releases');
export const versions = fs
  .readdirSync(notesDir)
  .filter((f) => f.endsWith('.md'))
  .map((f) => f.slice(0, -3))
  .filter((v) => compareVersions(v, version) <= 0)
  .sort((a, b) => compareVersions(b, a));

export const repo = 'https://github.com/subhashhhhhh/Matte';
const base = `${repo}/releases/download/${manifest.tag}`;
const mb = (key: string) => Math.max(1, Math.round((manifest.archives[key]?.size ?? 0) / 1_000_000));

export const downloads = [
  {
    slug: 'apple-silicon',
    name: 'Apple silicon',
    hint: 'M1 and later. About This Mac says “Chip”.',
    url: `${base}/Matte-${version}-AppleSilicon.dmg`,
    mb: mb('AppleSilicon'),
  },
  {
    slug: 'intel',
    name: 'Intel',
    hint: 'Older Macs. About This Mac says “Processor”.',
    url: `${base}/Matte-${version}-Intel.dmg`,
    mb: mb('Intel'),
  },
];
export const checksums = `${base}/SHA256SUMS-${version}.txt`;
export const brew = 'brew install --cask subhashhhhhh/matte/matte';
