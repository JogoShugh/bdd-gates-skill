# Stack: dotnet-csharp

Build-side changes that make the core gates meaningful in a .NET solution.
Expected layout (adjust `.claude/bdd-gates.json` if different):

```
src/MyApp.Domain/          # core, no infrastructure references
src/MyApp.Infrastructure/  # driven adapters (EF Core, LibGit2Sharp, HTTP clients)
src/MyApp.Api/             # driving adapters
tests/MyApp.Specs/         # Reqnroll features + step definitions
tests/MyApp.ArchitectureTests/
```

## 1. BDD runner: Reqnroll

SpecFlow reached end of life; Reqnroll is its maintained successor with the
same Gherkin and binding model.

```xml
<!-- tests/MyApp.Specs/MyApp.Specs.csproj -->
<PackageReference Include="Reqnroll.xUnit" Version="<latest>" />   <!-- or Reqnroll.NUnit -->
<PackageReference Include="Microsoft.NET.Test.Sdk" Version="<latest>" />
```

Copy `templates/reqnroll.json` into the specs project. It sets
`missingOrPendingStepsOutcome` to `Error`. Without that setting, a scenario
with undefined steps comes out Inconclusive, not failed, and a new scenario
never goes red.

## 2. BDD run logging (wrapper)

`dotnet test` has no hook that runs after a failed test run, so this stack
logs through `.claude/bdd-gates/bdd-run.sh`:

- `bddCommand` is the raw command (`dotnet test --nologo`). The wrapper runs
  it, records `BDD_RUN PASS|FAIL`, and returns its exit code.
- `checkCommand` is the wrapper, so every Stop gate run is also logged.
- `bddRawCommandRegex` makes the `gate-bash.sh` hook block a raw
  `dotnet test` from Claude. Filters still work through the wrapper:
  `.claude/bdd-gates/bdd-run.sh --filter "FullyQualifiedName~Checkout"`.
- A human running raw `dotnet test` in a terminal leaves no log line. The
  pre-commit check then fails and tells them to use the wrapper.

## 3. Complexity gate: Roslyn + SonarAnalyzer

Copy `templates/Directory.Build.props` to the solution root and merge
`templates/.editorconfig` into the root `.editorconfig`.

- `TreatWarningsAsErrors` turns analyzer warnings into build failures, so
  `lintCommand` (`dotnet build`) is a real gate.
- SonarAnalyzer.CSharp covers the Detekt-equivalent rules: cognitive
  complexity (S3776), method length (S138), parameter count (S107), nesting
  (S134), condition complexity (S1067), class size (S1200/S104).
- Microsoft CA1502 covers cyclomatic complexity.
- Use each analyzer's default thresholds. Do not invent numbers. Existing
  code may need its violations fixed or suppressed per file at first; tell the
  user instead of silently loosening rules.

## 4. Architecture gate

Two layers, strongest first:

1. **Project references (compile time).** `MyApp.Domain.csproj` references
   no infrastructure project or package. Any violation fails to compile. The
   domain project needs nothing more than that.
2. **NetArchTest (test time)** for rules that project references cannot
   express, such as namespace rules inside one assembly. Copy
   `templates/ArchitectureTests.cs` into `tests/MyApp.ArchitectureTests/` and add
   `NetArchTest.Rules` (or ArchUnitNET if the team prefers it).

## 5. Config review

Check `.claude/bdd-gates.json`:
- `prodPatterns` / `prodExcludePatterns` must match the real project folders.
  Step definition `.cs` files are test code and must be excluded.
- `featurePatterns` default is `*.feature` anywhere in the repo.
- If `dotnet build` is slow as a per-edit lint, point `lintCommand` at the
  domain project only: `dotnet build src/MyApp.Domain --nologo -v q`.

## 6. Red proof

Write one scenario with no step bindings. Run
`.claude/bdd-gates/bdd-run.sh`. Confirm it exits non-zero and the log gets
`BDD_RUN FAIL`.
