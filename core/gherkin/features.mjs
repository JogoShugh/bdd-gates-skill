#!/usr/bin/env node
// bdd-gates: the Gherkin, read the way Cucumber reads it, so the gates judge scenarios and not lines of text.
//
//   features.mjs changes --source worktree|staged [--base HEAD] -- <feature paths...>
//     Compares each feature at the base with its working-tree or staged version, scenario by scenario, and
//     prints JSON: { added, changed, removed, renamed, before, after, invalid }. A scenario is a Cucumber pickle: one per
//     Scenario, one per Examples row of a Scenario Outline, Background steps included. It is known by its file,
//     its name and its Examples row ("path :: name :: row"), and it changed when its steps did (keyword type,
//     text, doc string, table). Descriptions, comments, tags, blank lines and order change nothing.
//   features.mjs lint -- <feature files...>
//     gplint with bdd-gates' rules (gplintrc.json, rules/). Exit 1 and the findings when any file fails.
//   features.mjs results [--within <dir>] -- <messages.ndjson...>
//     One status per scenario from Cucumber's message stream (the "message" plugin): JSON
//     { "path :: name :: row": "PASSED" | "FAILED" | "UNDEFINED" | ... }. A scenario's status is its worst step's.
//     With --within, a uri (classpath:features/a.feature) becomes the feature's repo path inside that folder.
//   features.mjs verdict --source staged [--base HEAD] [--red <results.json>...] [--green <results.json>...]
//                        -- <feature paths...>
//     For the scenarios this change adds or changes: which failed in a red run, and which did not pass in the
//     green runs (the latest result of each counts). JSON { touched, red, unproven }.
//
// Run from the repository's root. Paths are repo-relative. A result's uri ("classpath:features/a.feature",
// "features/a.feature") matches a feature path that is it, or ends with "/" and it.
import { execFileSync, spawnSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { AstBuilder, GherkinClassicTokenMatcher, Parser, compile } from '@cucumber/gherkin';
import { IdGenerator } from '@cucumber/messages';

const here = dirname(fileURLToPath(import.meta.url));
const SEP = ' :: ';

function args(argv) {
  const at = argv.indexOf('--');
  const head = at < 0 ? argv : argv.slice(0, at);
  const opts = {};
  let name = null;
  head.forEach((word) => {
    if (word.startsWith('--')) {
      name = word.slice(2);
      opts[name] = opts[name] ?? [];
    } else if (name) {
      opts[name].push(word);
    }
  });
  return { opts, paths: at < 0 ? [] : argv.slice(at + 1).filter(Boolean) };
}
const one = (opts, key, fallback) => opts[key]?.[0] ?? fallback;

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

/** Scenario names and Examples rows by AST node id, from a Gherkin document. */
function labels(document) {
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
  if (document?.feature) visit(document.feature.children);
  return { names, rows };
}

/** "path :: name[ :: row]" for a pickle. */
function keyOf(path, pickle, { names, rows }) {
  const [scenarioId, rowId] = pickle.astNodeIds;
  let key = `${path}${SEP}${names.get(scenarioId) ?? pickle.name}`;
  if (rowId) key += `${SEP}${rows.get(rowId)}`;
  return key;
}

/** The pickles of one feature, as { key: content }; throws on text Cucumber cannot parse. */
function scenarios(path, source) {
  if (source == null || source.trim() === '') return {};
  const newId = IdGenerator.incrementing();
  const document = new Parser(new AstBuilder(newId), new GherkinClassicTokenMatcher()).parse(source);
  const found = labels(document);
  const result = {};
  compile(document, path, newId).forEach((pickle) => {
    let key = keyOf(path, pickle, found);
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

function changes(source, base, paths) {
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
  // A scenario that only moved (its file renamed) or was only retitled has the same steps under a new key: it
  // is renamed, not added, so a rename can never pass for a change of behaviour. Paired one to one.
  const gone = new Map();
  Object.keys(before).filter((key) => !(key in after)).forEach((key) => {
    gone.set(before[key], [...(gone.get(before[key]) ?? []), key]);
  });
  const renamed = [];
  const fromGone = (key, fits) => {
    const list = gone.get(after[key]) ?? [];
    const at = list.findIndex(fits);
    if (at < 0) return false;
    renamed.push({ from: list.splice(at, 1)[0], to: key });
    return true;
  };
  const added = Object.keys(after).filter((key) => !(key in before)).filter((key) => !fromGone(key, () => true));
  // Two scenarios of one name are told apart by order ("x", "x (again)"), so deleting the first shifts the
  // second into its key. Only that is a shift: a key whose steps are now those of its own "(again)" that went.
  // Any other scenario rewritten to the steps of one deleted is a change.
  const changed = Object.keys(after).filter((key) => key in before && before[key] !== after[key])
    .filter((key) => !fromGone(key, (from) => from.startsWith(`${key} (again)`)));
  return {
    added,
    changed,
    removed: [...gone.values()].flat(),
    renamed,
    invalid,
    before: tally(before, featuresBefore),
    after: tally(after, featuresAfter),
  };
}

// Worst first: a scenario's status is the worst of its steps'.
const SEVERITY = ['FAILED', 'AMBIGUOUS', 'UNDEFINED', 'PENDING', 'UNKNOWN', 'SKIPPED', 'PASSED'];
const worse = (a, b) => (SEVERITY.indexOf(a) <= SEVERITY.indexOf(b) ? a : b);

/**
 * The repo path of a result's uri: under [within] (the build that ran it), the one tracked or new feature
 * file whose path ends with the uri's. Two builds can both have classpath:features/a.feature; this keeps
 * them apart. The uri as it is when nothing matches.
 */
function resolver(within) {
  const root = `${process.cwd()}/`;
  const inRepo = (uri) => {
    // A file: uri (or an absolute path) inside the repository: its repo path, as is.
    const path = uri.replace(/^file:(\/\/)?/i, '');
    return path.startsWith(root) ? path.slice(root.length) : null;
  };
  if (!within) return (uri) => inRepo(uri) ?? uri;
  const listed = git('ls-files', '--cached', '--others', '--exclude-standard', '--', within) ?? '';
  // Sources before copies a build made (build/resources, dist, target...), when both are there.
  const copy = /(^|\/)(build|out|dist|target|bin|obj|node_modules)\//;
  const files = listed.split('\n').filter((path) => path.endsWith('.feature'))
    .sort((a, b) => Number(copy.test(a)) - Number(copy.test(b)));
  return (uri) => {
    const local = inRepo(uri);
    if (local) return local;
    const tail = uriPath(uri);
    return files.find((path) => path === tail || path.endsWith(`/${tail}`)) ?? uri;
  };
}

/** One status per scenario from Cucumber message streams (NDJSON). */
function results(files, within) {
  const repoPath = resolver(within);
  const documents = new Map();
  const pickles = new Map();
  const testCases = new Map();
  const started = new Map();
  const status = new Map();
  const finished = [];
  files.filter((file) => existsSync(file)).forEach((file) => {
    readFileSync(file, 'utf8').split('\n').filter((line) => line.trim()).forEach((line) => {
      const m = JSON.parse(line);
      if (m.gherkinDocument) documents.set(m.gherkinDocument.uri, labels(m.gherkinDocument));
      if (m.pickle) pickles.set(m.pickle.id, m.pickle);
      if (m.testCase) testCases.set(m.testCase.id, m.testCase.pickleId);
      if (m.testCaseStarted) started.set(m.testCaseStarted.id, m.testCaseStarted.testCaseId);
      if (m.testStepFinished) {
        const id = m.testStepFinished.testCaseStartedId;
        status.set(id, worse(status.get(id) ?? 'PASSED', m.testStepFinished.testStepResult.status));
      }
      if (m.testCaseFinished && !m.testCaseFinished.willBeRetried) finished.push(m.testCaseFinished.testCaseStartedId);
    });
  });
  const out = {};
  finished.forEach((startedId) => {
    const pickle = pickles.get(testCases.get(started.get(startedId)));
    if (!pickle) return;
    const key = keyOf(repoPath(pickle.uri), pickle, documents.get(pickle.uri) ?? labels(null));
    out[key] = status.get(startedId) ?? 'PASSED';
  });
  return out;
}

const uriPath = (uri) => uri.replace(/^[a-z]+:/i, '').replace(/^\/*\.?\//, '');

/** The status [results] gives the changed scenario [key] ("path :: rest"), or undefined. */
function statusOf(key, all) {
  const at = key.indexOf(SEP);
  const path = key.slice(0, at);
  const rest = key.slice(at);
  const match = Object.keys(all).find((k) => {
    const i = k.indexOf(SEP);
    const tail = uriPath(k.slice(0, i));
    return k.slice(i) === rest && (path === tail || path.endsWith(`/${tail}`));
  });
  return match === undefined ? undefined : all[match];
}

function verdict(opts, paths) {
  const change = changes(one(opts, 'source', 'staged'), one(opts, 'base', 'HEAD'), paths);
  const touched = [...change.added, ...change.changed];
  const read = (file) => (existsSync(file) ? JSON.parse(readFileSync(file, 'utf8')) : {});
  const redRuns = (opts.red ?? []).map(read);
  // The latest green run that ran a scenario decides it.
  const green = Object.assign({}, ...(opts.green ?? []).map(read));
  const red = touched.filter((key) => redRuns.some((run) => {
    const s = statusOf(key, run);
    return s !== undefined && s !== 'PASSED' && s !== 'SKIPPED';
  }));
  const unproven = touched
    .map((key) => ({ key, status: statusOf(key, green) ?? 'NOT RUN' }))
    .filter(({ status }) => status !== 'PASSED');
  return { touched, red, unproven };
}

function lint(paths) {
  const bin = join(here, 'node_modules', 'gplint', 'bin', 'gplint.js');
  // The files come first: -r takes a list, and would swallow any file named after it.
  const run = spawnSync(process.execPath, [
    '--no-warnings', bin, ...paths, '-c', join(here, 'gplintrc.json'), '-r', join(here, 'rules'),
  ], { encoding: 'utf8' });
  process.stdout.write(run.stdout ?? '');
  process.stderr.write(run.stderr ?? '');
  return run.status ?? 1;
}

const [command, ...rest] = process.argv.slice(2);
const { opts, paths } = args(rest);
const print = (value) => process.stdout.write(`${JSON.stringify(value)}\n`);
if (command === 'changes') {
  print(changes(one(opts, 'source', 'worktree'), one(opts, 'base', 'HEAD'), paths));
} else if (command === 'lint') {
  process.exit(paths.length === 0 ? 0 : lint(paths));
} else if (command === 'results') {
  print(results(paths, one(opts, 'within', null)));
} else if (command === 'verdict') {
  print(verdict(opts, paths));
} else {
  process.stderr.write('usage: features.mjs changes|lint|results|verdict (see the head of this file)\n');
  process.exit(2);
}
