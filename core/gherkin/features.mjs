#!/usr/bin/env node
// bdd-gates: the Gherkin, read the way Cucumber reads it, so the gates judge scenarios and not lines of text.
//
//   features.mjs changes --source worktree|staged [--base HEAD] -- <feature paths...>
//     Compares each feature at the base with its working-tree or staged version, scenario by scenario, and
//     prints JSON: { added, changed, removed, before, after, invalid }. A scenario is a Cucumber pickle: one per
//     Scenario, one per Examples row of a Scenario Outline, Background steps included. It is known by its file,
//     its name and its Examples row, and it changed when its steps did (keyword type, text, doc string, table).
//     Descriptions, comments, tags, blank lines and order change nothing.
//   features.mjs lint -- <feature files...>
//     gplint with bdd-gates' rules (gplintrc.json, rules/). Exit 1 and the findings when any file fails.
//
// Run from the repository's root. Paths are repo-relative.
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AstBuilder, GherkinClassicTokenMatcher, Parser, compile } from '@cucumber/gherkin';
import { IdGenerator } from '@cucumber/messages';

const here = dirname(fileURLToPath(import.meta.url));

function args(argv) {
  const at = argv.indexOf('--');
  const opts = {};
  const head = at < 0 ? argv : argv.slice(0, at);
  for (let i = 0; i < head.length; i += 2) opts[head[i].replace(/^--/, '')] = head[i + 1];
  return { opts, paths: at < 0 ? [] : argv.slice(at + 1).filter(Boolean) };
}

function git(...a) {
  try {
    return execFileSync('git', a, { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], maxBuffer: 64 << 20 });
  } catch {
    return null;
  }
}

/** The feature's text at [source]: the base commit, the index, or the working tree; null when absent. */
function text(path, source, base) {
  if (source === 'base') return git('show', `${base}:${path}`);
  if (source === 'staged') return git('show', `:${path}`);
  return existsSync(path) ? readFileSync(path, 'utf8') : null;
}

/** The pickles of one feature, as { key: content }; throws on text Cucumber cannot parse. */
function scenarios(path, source) {
  if (source == null || source.trim() === '') return {};
  const newId = IdGenerator.incrementing();
  const document = new Parser(new AstBuilder(newId), new GherkinClassicTokenMatcher()).parse(source);
  const names = new Map();
  const rows = new Map();
  const visit = (children) => children.forEach((child) => {
    if (child.rule) visit(child.rule.children);
    const scenario = child.scenario;
    if (!scenario) return;
    names.set(scenario.id, scenario.name.trim());
    scenario.examples.forEach((examples) => examples.tableBody.forEach((row) => {
      rows.set(row.id, row.cells.map((cell) => cell.value.trim()).join(' | '));
    }));
  });
  if (document.feature) visit(document.feature.children);
  const result = {};
  compile(document, path, newId).forEach((pickle) => {
    const [scenarioId, rowId] = pickle.astNodeIds;
    let key = `${path} :: ${names.get(scenarioId) ?? pickle.name}`;
    if (rowId) key += ` :: ${rows.get(rowId)}`;
    while (key in result) key += ' (again)';
    result[key] = JSON.stringify(pickle.steps.map((step) => [
      step.type ?? 'Unknown',
      step.text.trim(),
      step.argument?.docString?.content ?? null,
      step.argument?.dataTable?.rows.map((row) => row.cells.map((cell) => cell.value)) ?? null,
    ]));
  });
  return result;
}

function tally(all, features) {
  const steps = { Context: 0, Action: 0, Outcome: 0, Unknown: 0 };
  Object.values(all).forEach((content) => JSON.parse(content).forEach(([type]) => { steps[type] = (steps[type] ?? 0) + 1; }));
  return { features, scenarios: Object.keys(all).length, given: steps.Context, when: steps.Action, then: steps.Outcome };
}

function changes({ source = 'worktree', base = 'HEAD' }, paths) {
  const before = {};
  const after = {};
  const invalid = [];
  let featuresBefore = 0;
  let featuresAfter = 0;
  paths.forEach((path) => {
    const old = text(path, 'base', base);
    const now = text(path, source, base);
    if (old != null) featuresBefore += 1;
    if (now != null) featuresAfter += 1;
    try {
      Object.assign(before, scenarios(path, old));
    } catch {
      // The base never parsed: everything now is new.
    }
    try {
      Object.assign(after, scenarios(path, now));
    } catch (error) {
      invalid.push({ path, error: String(error.message ?? error).split('\n')[0] });
    }
  });
  const added = Object.keys(after).filter((key) => !(key in before));
  const changed = Object.keys(after).filter((key) => key in before && before[key] !== after[key]);
  const removed = Object.keys(before).filter((key) => !(key in after));
  return {
    added, changed, removed, invalid,
    before: tally(before, featuresBefore),
    after: tally(after, featuresAfter),
  };
}

function lint(paths) {
  const bin = join(here, 'node_modules', 'gplint', 'bin', 'gplint.js');
  const run = spawnSync(process.execPath, [
    '--no-warnings', bin, '-c', join(here, 'gplintrc.json'), '-r', join(here, 'rules'), ...paths,
  ], { encoding: 'utf8' });
  process.stdout.write(run.stdout ?? '');
  process.stderr.write(run.stderr ?? '');
  return run.status ?? 1;
}

const [command, ...rest] = process.argv.slice(2);
const { opts, paths } = args(rest);
if (command === 'changes') {
  process.stdout.write(`${JSON.stringify(changes(opts, paths))}\n`);
} else if (command === 'lint') {
  process.exit(paths.length === 0 ? 0 : lint(paths));
} else {
  process.stderr.write('usage: features.mjs changes --source worktree|staged [--base HEAD] -- <paths...>\n'
    + '       features.mjs lint -- <paths...>\n');
  process.exit(2);
}
