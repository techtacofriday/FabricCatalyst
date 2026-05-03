# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

### Run all tests
```powershell
powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1
```

### Run tests with detailed output
```powershell
powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1 -Output Detailed
```

### Run a single test by name or tag
```powershell
powershell -NoProfile -File .\tasks\shared\tests\Invoke-Tests.ps1 -Output Detailed -Filter 'Compare-RoleAssignments'
```

Pester 5.0+ is required (not the Windows inbox version 3). The runner returns exit code 1 on test failures.

## Architecture

### Extension structure

The core logic lives in `extension/`:

- `extension/public/` — four entry-point functions, one per deployment mode
- `extension/private/` — twelve helper modules; `SharedFunctions.ps1` is the most important (809 lines)
- `extension/tests/` — Pester 5 test suite

### Four deployment modes

| Entry point | Purpose |
|---|---|
| `AutoMainFunction.ps1` | Git-enabled workspaces; auto-discovers items from branches |
| `CustomMainFunction.ps1` | Copies items from a template workspace; no Git integration |
| `MapMainFunction.ps1` | JSON-driven deployment for SQL-to-Fabric migration scenarios |
| `StateMainFunction.ps1` | Workspace governance: rules, domain assignments, what-if, removal |

Each mode has a corresponding Azure DevOps YAML pipeline under `devops/pipelines/fabriccatalyst/dataproduct/`.

### API layer

All three Microsoft API integrations go through `CallApiEndpoint` in `SharedFunctions.ps1`:

- **Fabric API** — workspace/item CRUD, capacity queries, LRO polling
- **Azure DevOps REST API** — pipeline queuing, git branch management
- **Microsoft Graph API** — UPN-to-ID resolution for users/groups

Auth tokens are stored as `$script:fabricRequestHeader`, `$script:devOpsRequestHeader`, `$script:graphRequestHeader`. Three auth modes are supported: `UserMFA`, `UserPSW`, `SrvPrincipal`.

Long-running operations (HTTP 202) are polled via `WaitForLongRunningOperation` until the operation reaches `Succeeded` or `Failed`.

### Tiered deployment

Items deploy in dependency order across three tiers, processed sequentially:

- **Tier 1** — Lakehouse, Warehouse, SQL Database (no dependencies)
- **Tier 2** — Notebook, Semantic Model (depend on Tier 1)
- **Tier 3** — Data Pipeline, Report (depend on Tier 2)

### Token substitution

Deployment configs are CSV files containing `#{TokenName}#` placeholders. A properties catalog (`$script:fabricItemsPropertiesCatalog`) is built at runtime using `{FQN}.{Property}` keys (e.g., workspace IDs, lakehouse connection strings). `Invoke-TokenSubstitution` resolves tokens; `Default.*` keys serve as fallbacks for generic tokens.

### Testability pattern

`New-FabricContext` creates an injectable context object. `CallApiEndpoint` and API-touching functions accept an optional `-Context` parameter; when omitted they fall back to `$script:` variables. This enables full unit testing without network calls or auth tokens — all tests in the suite are pure (no API calls).

### Pure functions (safe to test without mocking)

- `Resolve-NormalizedUpnList` — normalizes semicolon-separated UPN strings
- `Compare-RoleAssignments` — diffs desired vs existing role assignments, returns `ToAdd`/`ToRemove`
- `Invoke-TokenSubstitution` — replaces `#{token}#` patterns using a catalog
- `ReplaceTokens` — applies token substitution across CSV content lines
- `UpdateJsonValues` / `UpdatePropertyPath` — dot-path JSON property traversal and update (supports array indexing by position, name, and wildcard)

### Pipeline configuration

Azure DevOps pipelines are manually triggered (`trigger: none`). Each pipeline has two stages: **Build** (publish artifact) → **Deploy** (run the PowerShell entry point from the artifact). Secrets are pulled from Azure Key Vault at deploy time. Auth method is parameterized per pipeline run (`SrvPrincipal` or `UserPSW`); templates live in `devops/pipelines/fabriccatalyst/dataproduct/authMethod/`.

Deployment variable files are organized as:
```
devops/pipelines/fabriccatalyst/dataproduct/deployment/<DataProduct>/<mode>/variables-<layer>.yml
```

---

## Known issues and improvement backlog

This section tracks the remaining improvements identified in the April 2026 code review, ordered by priority. Update or remove entries as they are implemented.

### Priority #1 — Bugs (crashes / infinite loops) — DONE ✓

| # | File | Function | Issue |
|---|---|---|---|
| 1.1 | `SharedFunctions.ps1` | `WaitForLongRunningOperation` | `$attempMax` declared but never checked — `while ($true)` loops forever if operation never completes |
| 1.2 | `WorkspaceFunctions.ps1` | `WaitForPrivateEndpointToSucceeded` | `$resp` undefined in the `isException` error branch — should be `$lroResponse` |
| 1.3 | `SharedFunctions.ps1` | `GetAzStorageBlob` | `$blobName` referenced throughout body but never declared as a parameter — function always crashes |
| 1.4 | `WorkspaceFunctions.ps1` | `ConnectWorkspaceToGit` | `-method "PATCH "` has a trailing space — HTTP method is invalid, credentials update always fails |
| 1.5 | `ItemFunctions.ps1` | `CreateItem` | Warning log references `$notebookName` which is not a parameter — should be `$itemName` |

### Priority #2 — LRO header extraction not safely cast — DONE ✓

`CreateLakehouse`, `CreateWarehouse`, `CreateSqlDatabase`, and `GetItemDefinition` extract `x-ms-operation-id` and `Retry-After` without `[string]`/`[int]` casts and without `Select-Object -First 1`. When PowerShell returns the header as an array, `Start-Sleep` receives an array and throws. The fixed pattern (used in `ConnectWorkspaceToGit`) is:
```powershell
$operationId  = [string]($response.responseObject.Headers.'x-ms-operation-id' | Select-Object -First 1)
$retryInterval = [int]($response.responseObject.Headers.'Retry-After'         | Select-Object -First 1)
```

### Priority #3 — Code duplication — DONE ✓

- **`DeployPipelineStage` vs `DeployPipelineStageByOrder`** (`PipelineFunctions.ps1`) — `DeployPipelineStage` replaced with a simple loop over `DeployPipelineStageByOrder`, eliminating the duplicate LRO block and the repeated JSON parsing per iteration.

### Priority #4 — Testability gaps — DONE ✓

- **`WriteMessage` Debug/Develop cases** (`SharedFunctions.ps1`) — `$enableDiagnostics` → `$script:enableDiagnostics` in both branches; Debug messages now correctly fire.
- **`ConnectWorkspaceToGit`** (`WorkspaceFunctions.ps1`) — 7 bare variables prefixed with `$script:` (`$gitProviderType`, `$organizationName`, `$projectName`, `$repositoryName`, `$newBranchName`, `$itemsGitFolder`, `$fabricGitConnectionId`).
- **`Get-RemoteFile`** (`GitFunctions.ps1`) — `Invoke-RestMethod` replaced with `Invoke-WebRequest`, aligning with the mockable seam used by the rest of the codebase.
- **`GetUserOrGroupIdByUpn` Graph path** (`SharedFunctions.ps1`) — added optional `$Context` parameter; Graph base URL and headers now resolved from context when provided, falling back to `$script:` variables.

### Priority #5 — Role assignment sync gap in domain and pipeline functions - WAIVED ✓

`AddDomainUsers` (`DomainFunctions.ps1`) and `AddPipelineUsers` (`PipelineFunctions.ps1`) only **add** users; they never fetch existing assignments and remove stale ones. `AddWorkspaceUsers` was already fixed to use `Compare-RoleAssignments` for a full sync — the same approach should be applied here.

### Priority #6 — Wrong API endpoints in deployment pipeline functions — DONE ✓

`CreateDeploymentPipeline` lists via the Fabric API (`/deploymentPipelines`) but creates via the old Power BI API fragment `.0/myorg/pipelines` with no `-baseUrl`, so `CallApiEndpoint` prepends `$script:fabricBaseUrl` and produces a malformed URL. `AssignWorkspaceToPipelineStage` has the same problem. Both need updating to the Fabric API equivalents.

### Priority #7 — Naming convention inconsistency - WAIVED ✓

The codebase mixes unapproved PascalCase (`CreateWorkspace`, `CallApiEndpoint`), approved Verb-Noun (`Get-Workspaces`, `Compare-RoleAssignments`), and lowercase camelCase (`newBranchJsonBody`). A full migration to Verb-Noun is a large refactor with call-site impact across the four public entry points.

---

## Project identity & branding

FabricCatalyst is a personal open-source project by **Hector Lopez** (alias: **Svenchio**), published under the **TechTacoFriday** brand.

- Author: Svenchio (`svenchio@techtacofriday.com`)
- Brand: TechTacoFriday (`techtacofriday.com`)
- Extension domain: `fabriccatalyst.com`
- GitHub repository: `https://github.com/techtacofriday/FabricCatalyst`
- ADO Marketplace publisher: `techtacofriday`

**NEVER reference Avanade** in any content — code comments, commit messages, README, docs, or generated text. The project has no relationship with Avanade.

---

## Public entry-point backlog (completed April 2026)

All seven items from the April 2026 public entry-point review (`extension/public/*.ps1`) are resolved:

- **P1 Bugs** — Five runtime bugs fixed across `CustomMainFunction.ps1`, `MapMainFunction.ps1`, `StateMainFunction.ps1`: wrong variable scope, `exit 1` → `throw`, missing `$i = 0` capacity loop initializer.
- **P2 Hardcoded defaults** — Waived; user confirmed convenience defaults are intentional, not secrets.
- **P3 Dead null-guards** — Removed from `AutoMainFunction.ps1` and `CustomMainFunction.ps1` after private-function throw migration.
- **P4 Redundant capacity API call** — Deduplicated in `MapMainFunction.ps1` (single `GetCapacities` call with inline filter).
- **P5 Code duplication** — CSV loading extracted to `Get-DeploymentCsvContent` in `SharedFunctions.ps1`; deeper extraction waived due to functional divergence between Auto and Custom paths.
- **P6 `DevOpsFunctions.ps1` never dot-sourced** — Module removed entirely.
- **P7 `$script:` vs bare variable access** — Fixed in `CustomizeFabricItems` and `DeployCustomFabricItems`; context threading extended to all downstream API-touching functions (`CreateLakehouse`, `GetLakehouse`, `GetLakehouseSqlEndpoint`, `CreateWarehouse`, `CreateSqlDatabase`, `CreateItem`, `GetConnections`, `WaitForLongRunningOperation`, and others). `DetokenizeConfigFile` updated with optional params + `$script:` fallback. 103 tests pass.

---

## User deployment prerequisites

When writing documentation or setup guides, all five of the following are required before a user can run a deployment:

1. **Service Principal** — registered in Entra ID; Microsoft Graph read permission (users and groups); Azure subscription read access; secret stored in Azure Key Vault.
2. **Fabric tenant** — F-SKU capacity or higher; SP granted capacity access; tenant setting "Service principals can use Fabric APIs" enabled.
3. **Azure DevOps** — SP granted Basic access level to the ADO organization; Contribute permission on the Fabric items Git repository; service connection created with "Grant access to all pipelines" enabled.
4. **Fabric Git connection** — DevOps Repository connection created inside Fabric using the SP; SP granted user access within target Fabric workspaces.
5. **ADO pipeline** — Pipeline created using FabricCatalyst extension tasks and triggered to run.
