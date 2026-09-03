/**
 * Fails if any dependency in package.json is a range rather than a version.
 *
 * CLAUDE.md: "Pin all dependencies. Lockfiles committed." The rest of this repo
 * pins exactly — `flutter_riverpod: 2.6.1`, `fastapi==0.115.6` — and a caret
 * here would make the dashboard the one place a dependency can move underneath
 * somebody without the file that names it changing. The lockfile alone is not
 * enough: `npm install` rewrites it from the ranges, so the range is what
 * actually decides.
 *
 * A file rather than a line of shell in the workflow, because a check that is
 * awkward to run locally is a check people find out about from CI.
 */

import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const pkg = JSON.parse(readFileSync(join(here, '..', 'package.json'), 'utf8'));

const floating = [];
for (const section of ['dependencies', 'devDependencies']) {
  for (const [name, spec] of Object.entries(pkg[section] ?? {})) {
    if (typeof spec === 'string' && /^[\^~>=<]/.test(spec)) {
      floating.push(`${name}: ${spec}`);
    }
  }
}

if (floating.length > 0) {
  console.error('These are not pinned:');
  for (const line of floating) console.error(`  ${line}`);
  console.error('');
  console.error('Set each to the exact version npm resolved, per CLAUDE.md.');
  process.exit(1);
}

console.log('ok - every dependency is pinned');
