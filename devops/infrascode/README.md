# FabricCatalyst Infrastructure — Deployment Guide

This package provisions the Azure infrastructure required to run FabricCatalyst automation.
It creates an Entra ID App Registration, security groups, a Key Vault, and all necessary
role assignments in a single idempotent script.

---

## What gets created

| Resource / assignment | Details |
|---|---|
| App Registration + Service Principal | Created (or resolved); deployer is ensured as **owner** of the App Registration |
| `-OwnerGroupName` group (existing or new) | Granted **Key Vault Administrator** on the new Key Vault; deployer is added as **member and owner** of this group |
| `-AutomationGroupName` group (existing or new) | Granted **Key Vault Secrets User** on the new Key Vault; SPN is added as **member**, deployer as **owner** |
| Resource group | Contains the Key Vault — **skipped when `-SkipKeyVault` is set** |
| Key Vault | Stores the SPN credentials (client ID, tenant ID, client secret) — **skipped when `-SkipKeyVault` is set** |
| Subscription Reader | Granted directly to the SPN — **always assigned** |
| Graph permissions | `User.Read.All` and `Group.Read.All` (application, admin-consented) |

> **Note — the Key Vault is optional.** The resource group and Key Vault exist purely as a
> convenient, secure place to store the SPN credentials after the script runs. The SPN itself,
> its permissions, the security groups, and the subscription Reader role are the real output of
> this process. If you already have a Key Vault you want to use, pass its name in `-KeyVaultName`
> and the script will create the resource group and deposit the credentials there. If you do not
> want any new Azure resources created at all, pass `-SkipKeyVault` — the credentials will be
> printed to the terminal instead and it is your responsibility to store them securely.

---

## Prerequisites

### Azure account permissions

The account you use to run this script must have all of the following:

- **Application Administrator** (or Global Administrator) in Entra ID
- **Owner** or **User Access Administrator** on the target subscription
- **Cloud Application Administrator** (or above) to grant tenant-wide admin consent

### Information to gather before you start

All parameters are mandatory — have these values ready before you run.

| Parameter | Where to find / how to choose |
|---|---|
| `-TenantId` | Azure Portal → Microsoft Entra ID → Overview |
| `-SubscriptionId` | Azure Portal → Subscriptions |
| `-ResourceGroupName` | Choose a name, e.g. `fabriccatalyst-rg` |
| `-KeyVaultName` | Must be globally unique, 3–24 chars, alphanumeric + hyphens only |
| `-Location` | Azure region slug, e.g. `norwayeast`, `westeurope` |
| `-SpnDisplayName` | Display name for the App Registration, e.g. `spn-fabcat-automation` |
| `-OwnerGroupName` | Security group to grant Key Vault Administrator on the new KV. Use an existing group (e.g. `sg_tenant_admins`) or a new name — the script creates it if absent |
| `-AutomationGroupName` | Security group whose members are granted Key Vault Secrets User on the new KV; the SPN is added as a member. Use an existing group or a new name — the script creates it if absent |
| `-TagOwner` | Value written to the `Owner` resource tag on all provisioned resources |
| `-TagManagedBy` | Value written to the `ManagedBy` resource tag on all provisioned resources |
| `-SkipKeyVault` | *(switch, optional)* Skips resource group and Key Vault creation. Credentials are printed to the terminal. `-ResourceGroupName` and `-KeyVaultName` are not required when this is set |

---

## Deployment steps

### 1. Open Azure Cloud Shell

1. Go to [portal.azure.com](https://portal.azure.com)
2. Click the **Cloud Shell** icon ( `>_` ) in the top navigation bar
3. If prompted, select **PowerShell** (not Bash)
4. If this is your first time, you will be asked to create a storage account — accept the defaults

> **Verify you are in the correct tenant.** Check the tenant name shown in the top-right
> corner of the portal. If you need to switch tenants, use the directory selector before
> opening Cloud Shell.

### 2. Upload the deployment package

1. In the Cloud Shell toolbar, click the **Upload/Download files** icon (looks like a page with an arrow)
2. Select **Upload**
3. Browse to and select **infrascode.zip**
4. Wait for the upload to complete — Cloud Shell will confirm it in the terminal

### 3. Extract and navigate to the package

Run the following in Cloud Shell:

```powershell
Expand-Archive infrascode.zip -DestinationPath ./infrascode -Force
cd infrascode
```

### 4. Run the setup script

Replace every placeholder with your own values before running:

```powershell
./setup-spn.ps1 `
    -TenantId            "<your-tenant-id>" `
    -SubscriptionId      "<your-subscription-id>" `
    -ResourceGroupName   "<resource-group-name>" `
    -KeyVaultName        "<key-vault-name>" `
    -Location            "<azure-region>" `
    -SpnDisplayName      "<app-registration-display-name>" `
    -OwnerGroupName      "<kv-admin-security-group-name>" `
    -AutomationGroupName "<kv-secrets-user-security-group-name>" `
    -TagOwner            "<owner-tag-value>" `
    -TagManagedBy        "<managed-by-tag-value>"
```

**If you DO NOT want to include a resource group & key vault:**

```powershell
./setup-spn.ps1 `
    -TenantId            "<your-tenant-id>" `
    -SubscriptionId      "<your-subscription-id>" `
    -Location            "<azure-region>" `
    -SpnDisplayName      "<app-registration-display-name>" `
    -OwnerGroupName      "<kv-admin-security-group-name>" `
    -AutomationGroupName "<kv-secrets-user-security-group-name>" `
    -TagOwner            "<owner-tag-value>" `
    -TagManagedBy        "<managed-by-tag-value>" `
    -SkipKeyVault
```

The script is **idempotent** — if it fails partway through, fix the issue and run it again
with the same parameters. It will skip anything already created.

### 5. Expected output

A successful run ends with a summary similar to this:

```
================================================================
  FabricCatalyst infrastructure setup complete.
----------------------------------------------------------------
  App Registration : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
  Service Principal: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx  (spn-fabcat-automation)
  Security groups  : sg-fabcat-owner, sg-fabcat-automation
  Key Vault        : https://<key-vault-name>.vault.azure.net/
  Subscription role: Reader on <subscription-id>
  Graph permissions: User.Read.All, Group.Read.All (Application, consented)
----------------------------------------------------------------
  Next steps (manual):
    1. Add the SPN to your Azure DevOps organization (Basic access)
    2. Install the FabricCatalyst extension from the ADO Marketplace
    3. Create an ARM service connection using the SPN credentials
    4. Complete the Fabric portal steps in docs/prerequisites.md
================================================================
```

---

## Troubleshooting

| Error | Likely cause | Fix |
|---|---|---|
| `Insufficient privileges` on admin consent | Account lacks Cloud App Administrator or above | Ask a Global Admin to re-run the script, or grant consent manually in Entra ID |
| `KeyVault name already exists` | The Key Vault name is taken globally | Choose a different `-KeyVaultName` |
| `AuthorizationFailed` on role assignment | Account lacks Owner / User Access Administrator on the subscription | Ask a subscription Owner to grant you the role, then re-run |
| `403` writing Key Vault secrets | RBAC propagation lag | The script waits 30 s automatically; if it still fails, wait a minute and re-run |
