# Contributing to FabricCatalyst

Thanks for considering a contribution. FabricCatalyst is a practitioner tool — built to solve real problems, not to be a polished product. If something is broken, missing, or harder to use than it should be, that is worth fixing.

---

## What kinds of contributions are useful

- **Bug reports** — especially if you have repro steps and the relevant pipeline log output
- **Correctness fixes** — wrong API calls, broken parameter handling, off-by-one in deployment logic
- **Missing Fabric item types** — the supported item list is not exhaustive; PRs that add support for new Fabric artifact types are welcome
- **Documentation** — clearer explanations, missing parameter docs, updated prerequisites
- **Tests** — additional Pester test cases for existing logic, especially for edge cases

Large feature proposals are better started as an issue first, so we can discuss whether it fits the scope of the project before you invest time in the implementation.

---

## Reporting issues

When reporting a bug, please include:

- The task name and version (visible in the pipeline log header)
- The relevant section of the pipeline log — particularly any error messages and the preceding context
- Whether `Enable Diagnostics` was on (if not, turning it on and re-running often gives the root cause immediately)
- The deployment mode (Auto / Custom / Map)
- What you expected to happen vs what actually happened

You do not need to include pipeline variable values or service connection details.

---

## Development setup

### Requirements

- **PowerShell 5.1 or 7+** — the extension itself targets 5.1; the test runner works on both
- **Pester 5.x** — the Windows inbox version (3.x) will not work

Install Pester 5 if you have not already:

```powershell
Install-Module -Name Pester -Force -SkipPublisherCheck
```

### Repository layout

```
extension/
  public/       # four entry-point functions, one per deployment mode
  private/      # twelve helper modules (SharedFunctions.ps1 is the core)
  tests/        # Pester 5 test suite
tasks/
  AutoDeploy/   # ADO task wrapper for Auto mode
  CustomDeploy/ # ADO task wrapper for Custom mode
  MapDeploy/    # ADO task wrapper for Map mode
  shared/       # PowerShell modules shared across all tasks
devops/         # example Azure DevOps pipeline YAML files and deployment configs
```

### Running the tests

```powershell
powershell -NoProfile -File .\extension\tests\Invoke-Tests.ps1
```

With detailed output:

```powershell
powershell -NoProfile -File .\extension\tests\Invoke-Tests.ps1 -Output Detailed
```

Running a single test by name or tag:

```powershell
powershell -NoProfile -File .\extension\tests\Invoke-Tests.ps1 -Output Detailed -Filter 'Compare-RoleAssignments'
```

All tests are pure — they make no API calls and require no auth tokens. The test suite should pass on a clean machine with no Fabric access.

---

## Coding standards

The codebase uses a mix of naming conventions (historical reasons, not preference). For new code, follow these rules:

- **Functions that wrap API calls** — keep the existing PascalCase style (`CreateWorkspace`, `CallApiEndpoint`) to stay consistent with call sites
- **Pure utility functions** — use approved Verb-Noun (`Compare-RoleAssignments`, `Invoke-TokenSubstitution`)
- **Variables** — use camelCase (`$workspaceId`, `$retryInterval`)
- **Script-scope variables** — prefix with `$script:` (`$script:fabricRequestHeader`) — this is important for testability

Authentication tokens live in `$script:fabricRequestHeader`, `$script:devOpsRequestHeader`, and `$script:graphRequestHeader`. Do not access these directly from new functions — accept an optional `-Context` parameter instead and fall back to the script-scope variables when context is absent. This is the pattern that makes unit testing possible without mocking.

No comments that describe *what* the code does — only comments that explain *why*, when the reason is not obvious from the code itself.

---

## Writing tests

The test suite is in `extension/tests/SharedFunctions.Tests.ps1`. Tests use the Pester 5 `Describe` / `It` / `BeforeAll` structure.

The testability pattern in this codebase relies on pure functions and an injectable context object (`New-FabricContext`). When adding new logic:

1. Extract the pure computation into a standalone function with no API calls
2. Write Pester tests for that function directly
3. Call the pure function from the API-touching function

Functions that are safe to test without mocking:

- `Resolve-NormalizedUpnList` — UPN string normalization
- `Compare-RoleAssignments` — role assignment diffing (returns `ToAdd` / `ToRemove`)
- `Invoke-TokenSubstitution` — `#{token}#` pattern replacement
- `ReplaceTokens` — token substitution across CSV lines
- `UpdateJsonValues` / `UpdatePropertyPath` — dot-path JSON traversal and update

These are the model to follow for new testable logic.

---

## Pull request process

1. Fork the repository and create a branch from `main`
2. Make your changes — keep PRs focused; one thing per PR is easier to review
3. Run the full test suite and make sure it passes
4. Write a test for any new logic if the logic is extractable as a pure function
5. Update documentation if the change affects task parameters, prerequisites, or configuration format
6. Open the PR with a description of what changed and why

There is no formal review SLA. This is a solo-maintained project. Expect a response within a few days.

---

## Code of conduct

Be direct and constructive. Criticism of the code is welcome; personal attacks are not. If something in the codebase is wrong or poorly designed, say so clearly — that is more useful than politeness.

---

## Questions

Open an issue or reach out via [fabriccatalyst.com](https://fabriccatalyst.com).
