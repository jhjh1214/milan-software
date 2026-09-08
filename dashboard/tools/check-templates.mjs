/**
 * Fails a template binding to a directive its component never imported.
 *
 * Angular does not error on an unknown event name on a DOM element: it binds a
 * listener for an event of that name. So `(ngSubmit)` on a `<form>` in a
 * component that does not import FormsModule compiles, renders, and silently
 * does nothing — NgForm is what raises `ngSubmit`, and without it no such event
 * is ever fired. The Add somebody button on the people screen shipped that way.
 *
 * The reason it survived is worth naming: every test on that screen called the
 * component method directly, so the unit was right and only the wiring to it
 * was wrong. A behavioural test cannot see that. This check can.
 *
 * Scope, stated honestly: it pairs each `*.html` with the `*.ts` beside it, the
 * convention every component in this app follows. A component with an inline
 * template, or one whose template lives elsewhere, is not covered — and neither
 * is the general problem, which is any structural directive used without its
 * import. This checks the one that has actually bitten.
 *
 * A file rather than a line of shell in the workflow, because a check that is
 * awkward to run locally is a check people find out about from CI.
 *
 *     node tools/check-templates.mjs
 */

import { readFileSync, readdirSync, statSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const here = dirname(fileURLToPath(import.meta.url));
const src = join(here, '..', 'src');

/**
 * Each binding that only works when a particular module is imported.
 *
 * Add to this when something else is found the hard way, not speculatively:
 * a rule nobody has been bitten by is a rule that gets deleted the first time
 * it is inconvenient.
 */
const NEEDS = [
  {
    binding: '(ngSubmit)',
    module: 'FormsModule',
    why: 'NgForm raises ngSubmit, and NgForm comes from FormsModule. Without it this binds a DOM event nothing fires. Use (submit) with preventDefault, or import FormsModule.',
  },
];

function templates(dir) {
  const found = [];
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) {
      found.push(...templates(path));
    } else if (name.endsWith('.html')) {
      found.push(path);
    }
  }
  return found;
}

/** Comments are dropped: the rule is explained in one of these templates. */
function withoutComments(html) {
  return html.replace(/<!--[\s\S]*?-->/g, '');
}

/**
 * The text of the standalone component's own `imports: [...]` array.
 *
 * Not "does the file mention this module anywhere" — a component can
 * `import { FormsModule } from '@angular/forms'` at the top and never add it
 * to `imports:`, which compiles, and is the exact same silent-nothing bug
 * this file exists to catch, one level removed. Empty when there is no
 * `@Component` decorator with an `imports` array to find.
 */
function importsArray(ts) {
  const match = ts.match(/imports\s*:\s*\[([^\]]*)\]/s);
  return match ? match[1] : '';
}

const problems = [];

for (const path of templates(src)) {
  const html = withoutComments(readFileSync(path, 'utf8'));
  const component = path.replace(/\.html$/, '.ts');
  let ts = '';
  try {
    ts = readFileSync(component, 'utf8');
  } catch {
    // No component beside it. index.html and anything else static.
    continue;
  }

  const declared = importsArray(ts);
  for (const need of NEEDS) {
    if (!html.includes(need.binding)) continue;
    if (declared.includes(need.module)) continue;
    problems.push(
      `${path}\n  uses ${need.binding} but ${component} does not import ${need.module}.\n  ${need.why}`,
    );
  }
}

if (problems.length > 0) {
  console.error('A template binds something its component cannot provide:');
  console.error('');
  for (const problem of problems) console.error(`  ${problem}\n`);
  process.exit(1);
}

console.log('ok - no template binds a directive its component never imported');
