# Prerequisites

Before you can run a FabricCatalyst deployment, several components need to be in place across Azure, Azure DevOps, and Microsoft Fabric. Work through the steps in order — each one depends on the previous.

> **Automation:** `devops/infrascode/fabriccatalyst/setup-spn.ps1` automates Step 1 in full (SPN, Graph permissions, Key Vault, security groups, role assignments). The Azure DevOps and Fabric portal steps must be done manually.

---

## Step 1 — Microsoft Azure portal

### Task 1: App Registration and Service Principal

> Automated by `setup-spn.ps1`.

1. Register a new App in **Entra ID > App registrations > New registration**. Give it a descriptive name (e.g., `spn-fabcat-automation`). No redirect URI needed.
2. After creation, note the **Application (client) ID** and the **Directory (tenant) ID**.
3. Go to **API permissions > Add a permission > Microsoft Graph > Application permissions** and add:
   - `User.ReadBasic.All` (or `User.Read.All`)
   - `Group.Read.All`
4. Click **Grant admin consent for \<your organization\>**. Without this the permissions are pending and Graph calls will fail with 401.
5. Grant the SPN the **Reader** RBAC role at subscription scope — this lets FabricCatalyst enumerate workspaces, capacities, and resource metadata.

The script also creates two Entra ID security groups used for Key Vault and Fabric access:

| Group | Purpose |
|---|---|
| `sg-fabcat-owner` | Deployment team administrators. Gets Key Vault Administrator role. |
| `sg-fabcat-automation` | Contains the SPN. Gets Key Vault Secrets User role. Used to grant Fabric permissions as a group. |

Granting Fabric permissions to `sg-fabcat-automation` rather than directly to the SPN makes it easier to add or rotate automation identities later without revisiting the Fabric admin portal.

### Task 2: Azure Key Vault

> Automated by `setup-spn.ps1` (via `main.bicep`).

1. Create (or reuse) an Azure Key Vault to store the SPN secret securely.
2. The script stores three secrets automatically:
   - `scrt-entraid-automation-srvprincipal-clientid`
   - `scrt-entraid-automation-srvprincipal-tenantid`
   - `scrt-entraid-automation-srvprincipal-password`
3. Role assignments applied at Key Vault scope:
   - `sg-fabcat-owner` → **Key Vault Administrator**
   - `sg-fabcat-automation` → **Key Vault Secrets User**

### Running the setup script

```powershell
Connect-AzAccount -TenantId <tenantId>

.\devops\infrascode\fabriccatalyst\setup-spn.ps1 `
    -SubscriptionId    "00000000-0000-0000-0000-000000000000" `
    -TenantId          "00000000-0000-0000-0000-000000000000" `
    -ResourceGroupName "fabriccatalyst-d-rg" `
    -KeyVaultName      "fabcat-shared-d-kv"
```

The script is idempotent — re-running it with the same parameters is safe and skips anything that already exists.

---

## Step 2 — Azure DevOps Services portal

### Task 1: Add the Service Principal to your DevOps organization

1. Go to **Organization settings > Users > Add users**.
2. Search for the SPN by display name and add it with:
   - Access level: **Basic**
   - Role on the DevOps project: **Contributor**

### Task 2: Install the FabricCatalyst extension

1. Go to **Organization settings > Extensions > Browse Marketplace**.
2. Search for **FabricCatalyst**.
3. Click **Get it free** and select your organization, then click **Install**.

Once installed, the three FabricCatalyst tasks will appear in the pipeline task picker under the **Deploy** category.

### Task 3: Create a Service Connection at project level

The service connection is how FabricCatalyst authenticates to the Fabric, Graph, and DevOps APIs at pipeline runtime. No variable group is needed — the extension reads credentials directly from the connection.

1. Go to **Project settings > Service connections > New service connection**.
2. Select **Azure Resource Manager**.
3. Choose **App registration or managed identity (manual)** with credential type **Secret**.
4. Set scope level to **Subscription** and provide:
   - Azure subscription name and ID
   - SPN client ID (from the Key Vault secret `scrt-entraid-automation-srvprincipal-clientid`)
   - Tenant ID (from `scrt-entraid-automation-srvprincipal-tenantid`)
   - SPN client secret (from `scrt-entraid-automation-srvprincipal-password`)
   - Service connection name and description
5. Enable **Grant access to all pipelines**.

Note the service connection name — this is the value you put in the `azureSubscription` task parameter.

---

## Step 3 — Microsoft Fabric portal

### Task 1: Admin portal — tenant settings and capacity

All of the following are configured under **Settings > Admin portal**.

**Capacity settings:**

1. Go to **Capacity settings > Fabric Capacity > \[your capacity\] > Contributors**.
2. Add the security group `sg-fabcat-automation` as a contributor.

**Tenant settings** — for each setting below, enable the toggle and grant access to the security group `sg-fabcat-automation`:

| Setting | Section in Admin portal |
|---|---|
| Create workspaces | Workspace settings |
| Service principals can create workspaces, connections, and deployment pipelines | Developer settings |
| Service principals can call Fabric public APIs | Developer settings |
| Service principals can access read-only admin APIs | Admin API settings |
| Service principals can access admin APIs used for updates | Admin API settings |

> If any of these settings is off you will see a 403 from the Fabric API. "Service principals can call Fabric public APIs" is the most common cause of first-run failures.

### Task 2: Create the Fabric Git connection

FabricCatalyst connects Fabric workspaces to Azure DevOps Git branches during deployment. This connection must exist before the first pipeline run.

1. Go to **Settings > Manage Connections and Gateways > Connections > + New**.
2. Create a **Cloud** connection of type **Azure DevOps - Source control**.
3. Set authentication method to **Service Principal** and provide:
   - Connection name — this value goes in the `fabricGitConnectionName` task parameter
   - Azure DevOps organization URL
   - SPN client ID, tenant ID, and client secret
4. After creation, open the connection and go to **Manage Users**.
5. Share the connection with `sg-fabcat-automation` as **Owner**.

> Create this connection using the SPN identity, not your personal account. A personal account connection breaks when credentials expire or when the account is removed from the organization.

---

## Common first-run issues

| Symptom | Likely cause |
|---|---|
| 403 on all Fabric API calls | "Service principals can call Fabric public APIs" tenant setting is off |
| 401 on Graph API calls | Admin consent was not granted for Graph application permissions |
| 403 on workspace creation | "Create workspaces" or "Service principals can create workspaces…" tenant setting is off |
| 403 on read-only Fabric calls | "Service principals can access read-only admin APIs" is off |
| Pipeline fails to read the repository | SPN does not have Basic access or Contributor role in ADO |
| Git connection fails during deployment | Fabric connection was created with a personal account, not the SPN |
| Items deploy but workspace stays unassigned to capacity | `sg-fabcat-automation` is not added as contributor to the Fabric capacity |
| Task not found in pipeline editor | FabricCatalyst extension is not installed in the ADO organization |
