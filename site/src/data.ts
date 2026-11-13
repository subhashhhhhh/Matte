import fs from 'node:fs';
import path from 'node:path';

// The newest release is the newest notes file in docs/releases (scripts/release.sh writes it
// with the release). The download names follow the release script and the Homebrew cask.
const notesDir = path.resolve(process.cwd(), '../docs/releases');

const parts = (v: string) => v.split('.').map(Number);
export const compareVersions = (a: string, b: string) => {
  const [x, y] = [parts(a), parts(b)];
  for (let i = 0; i < Math.max(x.length, y.length); i++) {
    const d = (x[i] ?? 0) - (y[i] ?? 0);
    if (d) return d;
  }
  return 0;
};

export const versions = fs
  .readdirSync(notesDir)
  .filter((f) => f.endsWith('.md'))
  .map((f) => f.slice(0, -3))
  .sort((a, b) => compareVersions(b, a));

export const version = versions[0];
export const repo = 'https://github.com/subhashhhhhh/Matte';
const base = `${repo}/releases/download/v${version}`;

export const downloads = [
  {
    slug: 'apple-silicon',
    name: 'Apple silicon',
    hint: 'M1 and later. About This Mac says “Chip”.',
    url: `${base}/Matte-${version}-AppleSilicon.dmg`,
  },
  {
    slug: 'intel',
    name: 'Intel',
    hint: 'Older Macs. About This Mac says “Processor”.',
    url: `${base}/Matte-${version}-Intel.dmg`,
  },
];
export const checksums = `${base}/SHA256SUMS-${version}.txt`;
export const brew = 'brew install --cask subhashhhhhh/matte/matte';
