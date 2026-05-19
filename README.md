# FabricCatalyst

**Automated CI/CD and environment provisioning for Microsoft Fabric — from your Azure DevOps pipeline.**

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![ADO Marketplace](https://img.shields.io/badge/ADO%20Marketplace-techtacofriday-0078D4?logo=azuredevops)](https://marketplace.visualstudio.com/publishers/techtacofriday)
[![fabriccatalyst.com](https://img.shields.io/badge/docs-fabriccatalyst.com-black)](https://fabriccatalyst.com)

---

## Why this exists

Microsoft Fabric's deployment tooling is improving — but there is still a significant gap between what Fabric gives you out of the box and what a proper DevOps workflow requires.

Git integration exists, but it does not provision workspaces. Deployment pipelines exist, but they are UI-driven and do not cover infrastructure. You can call the REST API directly, but then you are writing your own auth layer, retry logic, long-running operation polling, and dependency ordering from scratch.

If you want repeatable, automated deployments across dev, test, and prod environments — the kind of thing you would take for granted in Azure with Bicep and Azure DevOps — Fabric does not have a first-class answer for that yet. FabricCatalyst is mine.

It is an Azure DevOps extension that handles workspace provisioning, Git wiring, tiered item deployment, and environment-specific configuration in pipeline tasks that slot into your existing ADO workflows.

---

## Tasks

| Task | When to use it |
|---|---|
| **FabricCatalyst - Auto Deployment** | Git-connected workspaces across environments. Discovers items from a branch and deploys in dependency order. The primary task for teams adopting DevOps-first Fabric workflows. |
| **FabricCatalyst - Map Deployment** | JSON-map-driven deployment. The map declares a domain → sub-domain → workspace → items hierarchy; the task provisions each workspace and deploys items with inline environment-specific configuration. Use for SQL-to-Fabric migration scenarios where items are not yet Git-connected. |
| **FabricCatalyst - Promote Stage** | Promotes items from one Fabric deployment pipeline stage to the next, identified by display name. Use when advancing content through dev → test → prod inside a Fabric deployment pipeline. |
| **FabricCatalyst - Update From Git** | Syncs a Fabric workspace from its connected Git branch. Optionally patches Git credentials, binds semantic models to connections, and runs post-sync notebooks for row-level security setup. |

Auto Deployment deploys in dependency order across three tiers:

- **Tier 1** — Lakehouse, Warehouse, SQL Database (no dependencies)
- **Tier 2** — Notebook, Semantic Model (depend on Tier 1)
- **Tier 3** — Data Pipeline, Report (depend on Tier 2)

You do not manage deployment order. FabricCatalyst does.

---

## Prerequisites

There are several moving parts to set up before your first deployment. The process involves an Entra ID service principal, Fabric tenant settings, Azure DevOps permissions, and a Fabric connection — all connected together.

Full step-by-step instructions: [docs/prerequisites.md](docs/prerequisites.md)

The short version:

1. Register a **Service Principal** in Entra ID with Microsoft Graph read access
2. Store the SP secret in **Azure Key Vault** (recommended)
3. Enable the **"Service principals can use Fabric APIs"** tenant setting in the Fabric admin portal
4. Assign the SP to your **Fabric capacity**
5. Grant the SP **Basic access** in your Azure DevOps organization and **Contribute** on the target repository
6. Create a **DevOps Repository connection** in Fabric using the SP

---

## Getting started

**1. Install the extension**

Install FabricCatalyst from the [Azure DevOps Marketplace](https://marketplace.visualstudio.com/publishers/techtacofriday) into your ADO organization.

**2. Create a service connection**

In your ADO project, create an Azure Resource Manager service connection pointing to the service principal. This connection is how FabricCatalyst authenticates to the Fabric, Graph, and DevOps APIs.

**3. Add a task to your pipeline**

Minimal Auto Deployment example:

```yaml
- task: FabricCatalystAutoDeploy@1
  displayName: Deploy Fabric workspaces
  inputs:
    azureSubscription: 'my-fabric-service-connection'
    workspacePrefix: 'MyProduct'
    capacityName: 'my-capacity'
    environmentList: '[{"code":"dev","gitEnabled":1},{"code":"uat","gitEnabled":0}]'
    fabricGitConnectionName: 'MyFabricGitConnection'
    organizationName: 'myorg'
    projectName: 'MyProject'
    repositoryName: 'fabric-items'
    sourceBranchName: 'main'
    itemsGitFolder: '/fabric/gitenabled'
    deploymentDirectoryPath: 'devops/pipelines/fabriccatalyst/dataproduct/deployment'
```

This creates (or updates) workspaces named `ws_MyProduct_dev` and `ws_MyProduct_uat`, connects the dev workspace to the specified Git branch, deploys all Fabric items in tier order, and syncs workspace role assignments.

**Map Deployment example:**

```yaml
- task: FabricCatalystMapDeploy@1
  displayName: Deploy Fabric items from map
  inputs:
    azureSubscription: 'my-fabric-service-connection'
    organizationName: 'myorg'
    projectName: 'MyProject'
    repositoryName: 'fabric-items'
    sourceBranchName: 'main'
    jsonMapFileName: '_sqlMeetsFabric.json'
    deploymentDirectoryPath: 'devops/pipelines/fabriccatalyst/dataproduct/deployment/map'
    deploymentDefinitionsPath: 'devops/pipelines/fabriccatalyst/dataproduct/deployment/map/definitions'
```

The task reads the JSON map file from `deploymentDirectoryPath`, provisions each workspace declared in the map, and deploys the items listed under each workspace. Item definition files (Notebooks, Semantic Models, Data Pipelines) are read from `deploymentDefinitionsPath`.

To read item definitions from a GitHub repository, set `gitProviderType` to `GitHub` and supply a PAT. The `projectName` parameter is not used in GitHub mode — only `organizationName` (the GitHub org or user) and `repositoryName` are needed:

```yaml
- task: FabricCatalystMapDeploy@1
  displayName: Deploy Fabric items from map (GitHub source)
  inputs:
    azureSubscription: 'my-fabric-service-connection'
    organizationName: 'my-github-org'
    repositoryName: 'fabric-items'
    sourceBranchName: 'main'
    gitProviderType: 'GitHub'
    externalGitPat: '$(GitHubPat)'
    jsonMapFileName: '_sqlMeetsFabric.json'
    deploymentDirectoryPath: 'devops/pipelines/fabriccatalyst/dataproduct/deployment/map'
```

When reading from an external Azure DevOps tenant (a different org from the one running the pipeline), set `gitProviderType` to `AzureDevOps` and supply a PAT for that tenant via `externalGitPat`. The task will use Basic authentication with the provided PAT instead of the service connection token.

**Promote Stage example:**

```yaml
- task: FabricCatalystPromoteStage@1
  displayName: Promote to UAT
  inputs:
    azureSubscription: 'my-fabric-service-connection'
    deploymentPipelineName: 'MyProduct'
    targetStageName: 'uat'
```

The Fabric deployment pipeline must be named `pl_MyProduct`. The task looks up the stage named `uat` and promotes items from the preceding stage into it.

**Update From Git example:**

```yaml
- task: FabricCatalystUpdateFromGit@1
  displayName: Sync workspace from Git
  inputs:
    azureSubscription: 'my-fabric-service-connection'
    workspaceName: 'ws_MyProduct_dev'
    isWorkspaceGitEnabled: true
    fabricGitConnectionName: 'MyFabricGitConnection'
    semanticModelsBinding: '[{"modelName":"*","cnnName":"my-connection"}]'
    folderName: 'Vertipaq'
```

This patches Git credentials on the workspace, triggers an `updateFromGit` sync, binds all semantic models to `my-connection` (wildcard), then runs every notebook in the `Vertipaq` folder.

**4. Run it**

Trigger the pipeline. Watch the logs. The first run provisions everything; subsequent runs are idempotent — existing workspaces and items are updated, not recreated.

---

## Configuration

Deployment configuration lives in CSV files in your repository, organized by data product and deployment mode:

```
devops/pipelines/fabriccatalyst/dataproduct/deployment/
  <DataProduct>/
    auto/
      config.csv          # environment-specific values for Auto mode
    custom/
      config-dev.csv
      config-uat.csv
    map/
      _myMap.json         # item mapping for Map mode
```

CSV configs use `#{TokenName}#` placeholders that get substituted at deploy time. Workspace IDs, lakehouse connection strings, and environment-specific values are all resolved this way. The `Default.*` token namespace provides fallbacks for generic tokens that are the same across environments.

Example configs for each mode are included under `devops/pipelines/fabriccatalyst/dataproduct/deployment/Default/`.

### JSON path targeting

The `jsonPath` column in your config CSV lets you reach into any property inside a Fabric item's definition file and replace its value at deploy time. This is how FabricCatalyst swaps out workspace IDs, lakehouse connections, and any other environment-specific value inside Notebooks, Semantic Models, Data Pipelines, and other item types — without touching the source files in Git.

#### How it works

FabricCatalyst reads the item definition files from your Git branch, locates the property named by `jsonPath`, replaces its value with the `token` column, and sends the updated definition to the Fabric API. Paths use dot-separated notation that mirrors the JSON structure of the definition file.

Given this Fabric Notebook metadata block:

```json
{
  "kernel_info": {
    "name": "synapse_pyspark"
  },
  "dependencies": {
    "lakehouse": {
      "default_lakehouse": "4cd8b02e-5c81-4ffe-9fb4-9bbdfa0ec101",
      "default_lakehouse_name": "LH_Bronze",
      "default_lakehouse_workspace_id": "1c9fb6cc-c769-4109-8bfa-a93f1cf588c2",
      "known_lakehouses": [
        { "id": "49dfdb9d-5e24-419c-a5f5-91d2183797fe" }
      ]
    }
  }
}
```

A matching config CSV looks like this (columns: `name`, `type`, `jsonPath`, `token`):

```csv
name,type,jsonPath,token
*,Notebook,kernel_info.name,synapse_pyspark
*,Notebook,dependencies.lakehouse.default_lakehouse,#{Default.Lakehouse.Id}#
*,Notebook,dependencies.lakehouse.default_lakehouse_name,LH_Bronze
*,Notebook,dependencies.lakehouse.default_lakehouse_workspace_id,#{MyWorkspace.Id}#
```

#### Path syntax reference

**Simple property** — direct or nested property access:

```
kernel_info.name
dependencies.lakehouse.default_lakehouse
dependencies.lakehouse.default_lakehouse_workspace_id
```

**Array element by numeric index** — targets a single element by its position:

```
dependencies.lakehouse.known_lakehouses[0].id
activities[1].typeProperties.source
```

**Array element by name** — targets the element whose `name` property matches the key (implicit shorthand):

```
activities['CopyFromSQL'].typeProperties.source.type
parameters['environmentName'].defaultValue
```

**Array element by any property** — use `prop=value` syntax to match on a property other than `name`:

```
activities['type=Copy'].typeProperties.source.type
known_lakehouses['id=49dfdb9d-5e24-419c-a5f5-91d2183797fe'].id
```

**Wildcard** — applies the value to every element in the array:

```
activities[*].dependsOn
known_lakehouses[*].workspace_id
```

#### Replacing an entire array element

Omitting the trailing property makes the array element itself the write target. The token value must be a valid JSON object string. This is useful for fully replacing a lakehouse attachment, a pipeline activity definition, or any other structured block.

| `jsonPath` | Effect |
|---|---|
| `known_lakehouses[0]` | Replaces the entire object at index 0 |
| `known_lakehouses['id=old-guid']` | Replaces the object whose `id` equals `old-guid` |
| `known_lakehouses[*]` | Replaces every object in the array |

Example CSV rows:

```csv
name,type,jsonPath,token
*,Notebook,known_lakehouses[0],"{""id"":""#{Default.Lakehouse.Id}#""}"
*,DataPipeline,activities['type=Copy'],"{""name"":""CopyData"",""type"":""Copy"",""typeProperties"":{...}}"
```

> When the token is a JSON object, wrap the entire column value in double quotes and escape inner double quotes by doubling them (`""`), as shown above.

#### Value type behaviour

FabricCatalyst never coerces string values to other types. What you write in the `token` column is what gets stored in the definition.

| Token value | Result |
|---|---|
| `synapse_pyspark` | String — stored as-is |
| `1433` | String — stored as `"1433"`, not the integer `1433` |
| `true` | String — stored as `"true"`, not the boolean `true` |
| `{"id":"abc"}` | JSON object — parsed and stored as a nested object |
| `["a","b"]` | JSON array — parsed and stored as an array |

### Task parameters

Each task has full inline help in the ADO pipeline editor. Key parameters per task:

**Auto Deployment**

| Parameter | Description |
|---|---|
| `azureSubscription` | Service connection for SP authentication |
| `workspacePrefix` | Base name for workspaces; environment code is appended automatically |
| `capacityName` | Display name of the Fabric capacity to assign workspaces to |
| `environmentList` | JSON array of `{"code":"dev","gitEnabled":1}` entries |
| `domainName` | Fabric domain to assign workspaces to; leave empty to skip |
| `subDomainName` | Fabric sub-domain; only used when `domainName` is set |
| `workspaceAdminsList` | **Required.** Semicolon-separated UPNs to assign as Workspace Admin; at least one admin is required so the workspace is accessible after deployment |
| `workspaceContributorsList` | Semicolon-separated UPNs to assign as Workspace Contributor; leave empty to skip |
| `workspaceMembersList` | Semicolon-separated UPNs to assign as Workspace Member; leave empty to skip |
| `workspaceViewersList` | Semicolon-separated UPNs to assign as Workspace Viewer; leave empty to skip |
| `fabricGitConnectionName` | Name of the Fabric Git connection configured in the workspace |
| `organizationName` | Azure DevOps organization name (the part after dev.azure.com/) |
| `projectName` | Azure DevOps project containing the Fabric items repository |
| `repositoryName` | Repository that holds the Fabric item definitions |
| `sourceBranchName` | Branch from which items are discovered and deployed |
| `itemsGitFolder` | Path in the repository where Git-enabled Fabric items are stored |
| `useEmptyBranch` | When true, creates a new empty branch before syncing |
| `createDeploymentPipeline` | When true, creates a Fabric deployment pipeline |
| `deploymentPipelineName` | Name of the deployment pipeline to create; required when `createDeploymentPipeline` is true |
| `pipelineAdminsList` | Semicolon-separated UPNs to assign as Pipeline Admin |
| `deploymentDirectoryPath` | Root path to deployment configuration folder in the repository |
| `customizeDeployment` | When true, applies token substitution from the deployment CSV before deploying |
| `enableDiagnostics` | Verbose logging for troubleshooting |

**Map Deployment**

| Parameter | Description |
|---|---|
| `azureSubscription` | Service connection for SP authentication |
| `organizationName` | Azure DevOps organization name (after dev.azure.com/) or GitHub org/user when `gitProviderType` is `GitHub` |
| `projectName` | Azure DevOps project containing the map file and item definitions; not used when `gitProviderType` is `GitHub` |
| `repositoryName` | Repository that holds the map file and item definitions |
| `sourceBranchName` | Branch from which to read the map file and item definitions |
| `gitProviderType` | Source of item definitions: `AzureDevOps` (default) or `GitHub`. When set to `GitHub`, the task uses the GitHub REST API and `projectName` is ignored. When set to `AzureDevOps` with an `externalGitPat`, Basic auth is used against the external tenant instead of the service connection token. |
| `externalGitPat` | PAT for an external Azure DevOps tenant or a GitHub repository. Must reference a secret pipeline variable, e.g. `$(ExternalGitPat)`. Leave empty when reading from the current Azure DevOps tenant. |
| `jsonMapFileName` | Name of the JSON map file (default: `_sqlMeetsFabric.json`) |
| `deploymentDirectoryPath` | Path in the repository to the folder containing the JSON map file |
| `deploymentDefinitionsPath` | Path in the repository to the root of item definition files (Notebooks, Semantic Models, etc.); required when the map includes items with definition parts |
| `fabricItemsLocation` | Source for item definition files (default: `LocalDirectory`) |
| `updateDefinition` | When true, pushes updated item definitions to the deployed workspace |
| `enableDiagnostics` | Verbose logging for troubleshooting |

### JSON map structure

The map file declares the full topology in a single JSON document. The task processes it top-down: domains → sub-domains → workspaces → items.

```json
{
  "domains": [
    {
      "name": "MyDomain",
      "active": 1,
      "subDomains": [
        {
          "name": "MySubDomain",
          "active": 1,
          "workspaces": [
            {
              "name": "Group-01",
              "active": 1,
              "capacity": "my-fabric-capacity",
              "items": {
                "lakehouses": [
                  { "name": "LH_Bronze", "active": 1 }
                ],
                "Notebooks": [
                  {
                    "name": "NB_LoadTable",
                    "active": 1,
                    "directory": "NB_LoadTable.Notebook",
                    "dfnFormat": "ipynb",
                    "dfnParts": [
                      {
                        "fileName": "notebook-content.py",
                        "csvData": [
                          {
                            "jsonPath": "dependencies.environment.workspaceId",
                            "token": "#{Group-01.Id}#"
                          },
                          {
                            "jsonPath": "dependencies.lakehouse.default_lakehouse",
                            "token": "#{Group-01.LH_Bronze.Id}#"
                          },
                          {
                            "jsonPath": "dependencies.lakehouse.default_lakehouse_workspace_id",
                            "token": "#{Group-01.Id}#"
                          }
                        ]
                      },
                      { "fileName": ".platform" }
                    ]
                  }
                ]
              },
              "rbacAssignments": [
                { "type": "Admins", "upnList": "user@example.com" }
              ]
            }
          ]
        }
      ]
    }
  ]
}
```

#### Token naming in map mode

Map mode builds a token catalog from workspace and item IDs as they are provisioned. Token names follow a `WorkspaceName.ItemName.Property` hierarchy using the names declared in the map:

| Token | Resolves to |
|---|---|
| `#{Group-01.Id}#` | ID of the workspace named `Group-01` |
| `#{Group-01.LH_Bronze.Id}#` | ID of the lakehouse named `LH_Bronze` in `Group-01` |
| `#{Group-01.LH_Bronze.Name}#` | Display name of the same lakehouse |

The `csvData` array inside a definition part provides inline token substitution — the same mechanism used by Auto Deployment CSV files, but declared directly in the map. Each entry targets a `jsonPath` inside the definition file and replaces it with the resolved token value before the item is deployed.

**Promote Stage**

| Parameter | Description |
|---|---|
| `azureSubscription` | Service connection for SP authentication |
| `deploymentPipelineName` | Fabric deployment pipeline name without the `pl_` prefix |
| `targetStageName` | Display name of the stage to promote INTO; items are promoted from the preceding stage |
| `enableDiagnostics` | Verbose logging for troubleshooting |

**Update From Git**

| Parameter | Description |
|---|---|
| `azureSubscription` | Service connection for SP authentication |
| `workspaceName` | Full name of the Fabric workspace to sync |
| `isWorkspaceGitEnabled` | When true, patches Git credentials and triggers an `updateFromGit` sync |
| `fabricGitConnectionName` | Name of the Fabric Git connection; required when `isWorkspaceGitEnabled` is true |
| `semanticModelsBinding` | JSON array mapping model names to connection names; use `"*"` as wildcard for all remaining models |
| `folderName` | Workspace folder containing notebooks to run after the sync (default: `Vertipaq`) |
| `enableDiagnostics` | Verbose logging for troubleshooting |

---

## Architecture overview

All API calls go through a single function (`CallApiEndpoint`) that handles auth headers, retries, and long-running operation polling. Three APIs are integrated:

- **Fabric REST API** — workspace and item CRUD, capacity queries
- **Azure DevOps REST API** — pipeline queuing, Git branch management
- **Microsoft Graph API** — UPN-to-ID resolution for user and group role assignments

Authentication tokens are obtained once per run from the ADO service connection and reused across all API calls.

The extension is written in PowerShell and packaged as a Node.js wrapper (the ADO task runner requirement). The PowerShell layer is the real implementation.

---

## Contributing

Contributions are welcome — bug reports, feature requests, and pull requests. See [CONTRIBUTING.md](CONTRIBUTING.md) for how to set up a development environment, run the test suite, and submit a PR.

---

## License

[MIT](LICENSE) — [Svenchio](https://techtacofriday.com) / [fabriccatalyst.com](https://fabriccatalyst.com)
