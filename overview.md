# FabricCatalyst

**Automated CI/CD and environment provisioning for Microsoft Fabric — from your Azure DevOps pipeline.**

Microsoft Fabric's deployment tooling is improving, but there is still a significant gap between what Fabric gives you out of the box and what a proper DevOps workflow requires. Workspace creation, Git wiring, tiered item deployment, and environment-specific configuration all need to be stitched together manually — or not at all.

FabricCatalyst fills that gap. It is an Azure DevOps extension that handles the full deployment lifecycle in pipeline tasks that slot into your existing ADO workflows.

---

## Tasks included

### FabricCatalyst - Auto Deployment

Deploys Fabric items from a Git-connected workspace using branch auto-discovery. Handles tiered deployment of Lakehouses, Warehouses, Notebooks, Semantic Models, Data Pipelines, and Reports in dependency order.

Use this when your team follows a DevOps-first Fabric workflow with Git-connected workspaces across dev, test, and prod environments.

### FabricCatalyst - Promote Stage

Promotes items from one Fabric deployment pipeline stage to the next, identified by display name. Looks up the target stage, resolves the preceding stage automatically, and handles the case where the source stage has no items yet.

Use this when you want to advance content through a Fabric deployment pipeline (dev → test → prod) from an ADO pipeline without touching the Fabric UI.

### FabricCatalyst - Update From Git

Syncs a Fabric workspace from its connected Git branch. Optionally patches Git credentials before the sync, binds semantic models to named connections, and runs post-sync notebooks (e.g. row-level security setup) from a designated workspace folder.

Use this when a workspace needs a Git sync followed by connection binding or notebook execution as part of a deployment step.

---

## How it works

**Auto Deployment** handles **tiered deployment** automatically — items deploy in dependency order so you never hit a "lakehouse not found" error mid-run:

- **Tier 1** — Lakehouse, Warehouse, SQL Database
- **Tier 2** — Notebook, Semantic Model
- **Tier 3** — Data Pipeline, Report

Authentication goes through a single **Azure Resource Manager service connection** using a service principal. The extension handles token acquisition for the Fabric API, Azure DevOps API, and Microsoft Graph API from that one connection — no variable groups, no manual token management.

Environment-specific configuration uses **CSV files with `#{token}#` placeholders** that get substituted at deploy time. Workspace IDs, lakehouse connection strings, and environment-specific values are all resolved from a properties catalog built at runtime.

---

## Quick start

**Auto Deployment** — provision and deploy Git-connected workspaces:

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

This creates (or updates) workspaces named `ws_MyProduct_dev` and `ws_MyProduct_uat`, connects the dev workspace to the specified Git branch, and deploys all Fabric items in tier order. Subsequent runs are idempotent.

**Promote Stage** — advance items through a Fabric deployment pipeline:

```yaml
- task: FabricCatalystPromoteStage@1
  displayName: Promote to UAT
  inputs:
    azureSubscription: 'my-fabric-service-connection'
    deploymentPipelineName: 'MyProduct'
    targetStageName: 'uat'
```

The Fabric deployment pipeline must be named `pl_MyProduct`. The task resolves the preceding stage automatically and promotes its items into `uat`.

**Update From Git** — sync a workspace and run post-sync setup:

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

Patches Git credentials, runs `updateFromGit`, binds all semantic models to `my-connection`, then runs every notebook in the `Vertipaq` folder.

---

## Requirements

- Microsoft Fabric-enabled tenant with **F-SKU capacity** or higher
- Azure DevOps service connection using a **service principal** with:
  - Microsoft Graph read permissions (users and groups)
  - Fabric tenant settings enabled for service principal API access
  - Basic access in the ADO organization

Full setup instructions and prerequisites: [github.com/fabriccatalyst/FabricCatalyst](https://github.com/fabriccatalyst/FabricCatalyst)

---

## Support and source

- **GitHub:** [github.com/fabriccatalyst/FabricCatalyst](https://github.com/fabriccatalyst/FabricCatalyst)
- **Website:** [fabriccatalyst.com](https://fabriccatalyst.com)
- **Author:** Svenchio — [techtacofriday.com](https://techtacofriday.com)

Report issues and contribute at the GitHub repository.
