# FabricCatalyst

**Automated CI/CD and environment provisioning for Microsoft Fabric — from your Azure DevOps pipeline.**

Microsoft Fabric's deployment tooling is improving, but there is still a significant gap between what Fabric gives you out of the box and what a proper DevOps workflow requires. Workspace creation, Git wiring, role assignments, and deployment pipeline setup all need to be stitched together manually — or not at all.

FabricCatalyst fills that gap. It is an Azure DevOps extension that handles the full deployment lifecycle in pipeline tasks that slot into your existing ADO workflows.

---

## Tasks included

### FabricCatalyst - Auto Deployment

Provisions Fabric workspaces, connects them to their Git branches using Fabric's built-in Git integration, assigns workspace roles, and optionally creates a Fabric deployment pipeline. Item content flows from Git through Fabric's native `updateFromGit` mechanism; content promotion between environments flows through Fabric's native deployment pipelines.

Use this when your team follows a DevOps-first Fabric workflow with Git-connected workspaces across dev, test, and prod environments.

### FabricCatalyst - Promote Stage

Promotes items from one Fabric deployment pipeline stage to the next, identified by display name. Looks up the target stage, resolves the preceding stage automatically, and handles the case where the source stage has no items yet.

Use this when you want to advance content through a Fabric deployment pipeline (dev → test → prod) from an ADO pipeline without touching the Fabric UI.

### FabricCatalyst - Map Deployment

Deploys Microsoft Fabric items defined in a JSON map file. The map describes a domain → sub-domain → workspace → items hierarchy. At runtime the task builds a token catalog from resolved workspace and item IDs, then uses that catalog to patch item definition files before deploying them to Fabric.

Use this for SQL-to-Fabric migration scenarios where workspaces and items are not yet in Git but you need repeatable, environment-aware deployments from a declarative map file.

### FabricCatalyst - Update From Git

Syncs a Fabric workspace from its connected Git branch. Optionally patches Git credentials before the sync, binds semantic models to named connections, and runs post-sync notebooks (e.g. row-level security setup) from a designated workspace folder.

Use this when a workspace needs a Git sync followed by connection binding or notebook execution as part of a deployment step.

---

## How it works

**Auto Deployment** provisions workspaces and wires them to Fabric's native capabilities:

1. Creates (or updates) workspaces named by prefix and environment code, assigns them to a capacity and optionally a domain. Provisions a managed identity for each workspace by default; can be disabled via `provisionIdentity` when the service principal lacks identity provisioning permissions.
2. For Git-enabled environments, creates a workspace branch in the source repository and connects the workspace to it using Fabric's built-in Git integration.
3. Syncs roles (Admins, Contributors, Members, Viewers) against the declared lists on every run.
4. Optionally creates a Fabric deployment pipeline so that `FabricCatalyst - Promote Stage` can advance content from dev to test to prod without touching the Fabric UI.

Item deployment is handled by Fabric itself — once the workspace is Git-connected, `FabricCatalyst - Update From Git` triggers the native `updateFromGit` sync. Promotion between stages is handled by `FabricCatalyst - Promote Stage` calling the Fabric deployment pipeline API. No custom tier ordering is involved.

Authentication goes through a single **Azure Resource Manager service connection** using a service principal. The extension handles token acquisition for the Fabric API, Azure DevOps API, and Microsoft Graph API from that one connection — no variable groups, no manual token management.

**Map Deployment** uses **CSV files and inline JSON with `#{token}#` placeholders** for environment-specific configuration. Workspace IDs, lakehouse connection strings, and any other environment-specific values are substituted at deploy time from a properties catalog built as items are provisioned.

---

## Quick start

**Auto Deployment** — provision and deploy Git-connected workspaces:

```yaml
- task: FabricCatalystAutoDeploy@2
  displayName: Deploy Fabric workspaces
  inputs:
    azureSubscription: 'my-devops-service-connection'
    workspacePrefix: 'my-awesome-data-product'
    capacityName: 'my-fabric-capacity'
    environmentList: '[{"code":"dev","gitEnabled":1},{"code":"uat","gitEnabled":0},{"code":"prod","gitEnabled":0}]'
    fabricGitConnectionName: 'my-fabric-devops-source-connection'
    organizationName: 'my-devops-org'
    projectName: 'my-devops-project'
    repositoryName: 'my-data-product-git-repo'
    sourceBranchName: 'main'
    itemsGitFolder: '/fabric'
```

This creates (or updates) workspaces named `ws_MyProduct_dev` and `ws_MyProduct_uat` and connects the dev workspace to the specified Git branch. Subsequent runs are idempotent. If the workspace branch already exists the task skips branch creation and proceeds directly to connecting the workspace to Git — safe for adding new environments to an already-deployed solution. Set `forceRecreateBranch: true` only when you need to reset a branch that is preventing a Git sync.

**Promote Stage** — advance items through a Fabric deployment pipeline:

```yaml
- task: FabricCatalystPromoteStage@1
  displayName: Promote to UAT
  inputs:
    azureSubscription: 'my-devops-service-connection'
    deploymentPipelineName: 'my-fabric-deployment-pipeline'
    targetStageName: 'uat'
```

The Fabric deployment pipeline must be named `pl_MyProduct`. The task resolves the preceding stage automatically and promotes its items into `uat`.

**Update From Git** — sync a workspace and run post-sync setup:

```yaml
- task: FabricCatalystUpdateFromGit@1
  displayName: Sync workspace from Git
  inputs:
    azureSubscription: 'my-devops-service-connection'
    workspaceName: 'ws_my-awesome-data-product_dev'
    isWorkspaceGitEnabled: true
    fabricGitConnectionName: 'my-fabric-devops-source-connection'
    semanticModelsBinding: '[{"modelName":"*","cnnName":"my-connection"}]'
    postDeploymentFolder: 'post-deployment'
```

Patches Git credentials, runs `updateFromGit`, binds all semantic models to `my-connection`, then runs every notebook in the `post-deployment` folder.

---

## Requirements

- Microsoft Fabric-enabled tenant with an active **capacity**
- Azure DevOps service connection using a **service principal** with:
  - Microsoft Graph read permissions (users and groups)
  - Fabric tenant settings enabled for service principal API access
  - Basic access in the ADO organization

Full setup instructions and prerequisites: [github.com/techtacofriday/FabricCatalyst](https://github.com/techtacofriday/FabricCatalyst)

---

## Support and source

- **GitHub:** [github.com/techtacofriday/FabricCatalyst](https://github.com/techtacofriday/FabricCatalyst)
- **Author:** Svenchio — [LinkedIn](www.linkedin.com/in/svenchio) | [Sessionize](https://sessionize.com/svenchio)
- **Blog:** TechTacoFriday — [techtacofriday.com](https://techtacofriday.com)

Report issues and contribute at the GitHub repository.
