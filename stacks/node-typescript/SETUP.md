# Stack: node-typescript

Build-side changes that make the core gates meaningful in a TypeScript
package. Expected layout (adjust `.claude/bdd-gates.json` if different):

```
src/                       # production code, built with tsc
features/*.feature         # Gherkin
features/step_definitions/ # steps
features/support/          # hooks, world, fixture server
tsconfig.json
```

Install the tools:

```bash
npm install --save-dev @cucumber/cucumber@<latest> eslint@<latest> \
  typescript-eslint@<latest> eslint-plugin-sonarjs@<latest> \
  typescript@<latest> dependency-cruiser@<latest>
```

Two limits on `<latest>`:

- Use the newest `typescript` inside the `peerDependencies` range of
  `typescript-eslint`, not the newest TypeScript. On 1 Nov 2026 that range
  ended below 6.1.0 and TypeScript's latest was 7.0.2.
- Check each tool's `engines.node` against the repo's Node version. On 1 Nov
  2026 the latest eslint, cucumber-js and dependency-cruiser needed Node
  newer than 20.18.

The red proof below last ran on Node 20.18.0 with eslint 9.13.0,
typescript-eslint 8.11.0, eslint-plugin-sonarjs 2.0.4, typescript 5.5.4,
@cucumber/cucumber 10.8.0 and dependency-cruiser 16.10.4.

## 1. BDD runner: cucumber-js

Copy `templates/cucumber.json` to the package root. It sets `strict: true`,
so an undefined step fails the run. Without strict, a new scenario can
pass with no bindings and never goes red. Do not turn it off. Set `paths` and
`import` if the features are not in `features/`.

## 2. BDD run logging (wrapper)

An npm `posttest` script does not run when the tests fail, and the failed run
is the one that matters most. This stack logs through
`.claude/bdd-gates/bdd-run.sh`:

- `bddCommand` is the raw command (`npx cucumber-js`). The wrapper runs it,
  records `BDD_RUN PASS|FAIL`, and returns its exit code.
- `checkCommand` starts with the wrapper, so every Stop gate run is logged.
- `bddRawCommandRegex` makes the `gate-bash.sh` hook block `npx cucumber-js`,
  `cucumber-js`, `npm test` and `npm run test` from Claude. Arguments still
  work through the wrapper: `.claude/bdd-gates/bdd-run.sh --tags @checkout`.
- A human running a raw command in a terminal leaves no log line. The
  pre-commit check then fails and tells them to use the wrapper.

If the repo has other test scripts, such as `npm run test:unit`, add them to
`bddRawCommandRegex` when they run the features.

## 3. Complexity gate: ESLint and tsc

Copy `templates/eslint.config.mjs` to the package root.

- Every rule is an error, so `npx eslint .` exits non-zero on a violation.
- Core rules and SonarJS rules use their own defaults. Do not invent numbers.
- `@typescript-eslint/consistent-type-assertions` with `assertionStyle: "never"`
  is a policy choice, not a threshold. No `as` casts, so raw JSON is parsed
  into types at the boundary. `as const` is not a cast and stays allowed.
- `noInlineConfig` makes ESLint ignore `eslint-disable` comments, so a
  violation cannot be switched off in the file that has it.
- `sonarjs/no-duplicate-string` finds a string only when it is repeated. One
  hard-coded string used once passes.

Copy `templates/tsconfig.strict.json` to the package root and extend it, so
`npx tsc --noEmit` also enforces `strict`, `noUnusedLocals` and
`noUnusedParameters`:

```json
{ "extends": "./tsconfig.strict.json", "include": ["src"] }
```

Existing code may have violations at first. Tell the user instead of loosening
a rule.

## 4. Architecture gate: dependency-cruiser

Copy `templates/.dependency-cruiser.cjs` to the package root. `npx depcruise src`
exits non-zero on any violation.

- `no-circular` stands as shipped.
- `layering-parse-decide-no-http` is a template: modules that parse and decide
  must not import the module that does HTTP, directly or through another
  module. Set its two `path` values to this repo's modules. A path that
  matches nothing passes silently, so prove it with one bad import.

## 5. Features that need a live service

The gate runs on every Stop, so features must be fast and offline. When
features exercise a client against a real service:

- **Fast run, in the gate.** Add a fixture server under `features/support/`
  that replays recorded representations. `bddCommand` starts the features
  against it. A green run needs no network and no running service.
- **Live run, outside the gate.** Keep a separate script that runs the same
  features against the real service. Run it by hand. It stays out of
  `bddCommand` and `checkCommand`, so a stopped service never blocks work.

Re-record the fixtures from the live service when its representations change.
Fixtures match `testPatterns`, so a refactor commit cannot change them.

## 6. Config review

Check `.claude/bdd-gates.json`:

- Patterns are shell case globs and `*` crosses folders. Do not write `**/`:
  `src/**/*.ts` needs a folder under `src/` and misses `src/index.ts`.
- Package in a subfolder: the defaults `*/src/*.ts` and `*.feature` already
  match. Commands run at the repo root, so prefix each one, for example
  `cd packages/client && npx eslint .`. Apply this to `lintCommand`, `bddCommand`
  and the lint and architecture parts of `checkCommand`.
- Features or step definitions in a folder the defaults do not name: add it
  to `testPatterns`, and to `prodExcludePatterns` if it is under `src/`.
- `.tsx` code: add `*.tsx` to `prodPatterns` and `lintPatterns`, and to `files`
  in `eslint.config.mjs`.

## 7. Red proof

Each check must fail for the stated reason. Remove each probe afterward.

| Probe | Command | Expected result |
|---|---|---|
| A scenario with no step bindings | `.claude/bdd-gates/bdd-run.sh` | Exit 1, and `.claude/tdd-events.log` gets `BDD_RUN FAIL` |
| One function with 11 statements in `src/` | `npx eslint .` | Exit 1, `max-statements` |
| `export const f = (v: unknown): string => v as string;` in `src/` | `npx eslint .` | Exit 1, `@typescript-eslint/consistent-type-assertions` |
