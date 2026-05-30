
//******************************************************************
// SCOPE
// Subscription-scoped so we can create the resource group and assign
// roles at subscription level from a single deployment.
//******************************************************************
targetScope = 'subscription'

//******************************************************************
// INPUT PARAMETERS
//******************************************************************
@description('Azure Tenant ID')
param azTenantId string

@description('Azure Subscription ID')
param azSubscriptionId string

@description('Resource group name — ignored when skipKeyVault is true')
param azResourceGroupName string = ''

@description('Azure region for all resources')
param azResourceGroupLocation string = 'norwayeast'

@description('Key Vault name (3-24 chars, globally unique) — ignored when skipKeyVault is true')
param azKeyVaultName string = ''

@description('Object ID of the Service Principal — assigned subscription Reader directly')
param spnObjectId string

@description('Object ID of the owner security group — assigned Key Vault Administrator')
param ownerGroupObjectId string

@description('Object ID of the automation security group — assigned Key Vault Secrets User')
param automationGroupObjectId string

@description('Value for the Owner resource tag')
param tagOwner string

@description('Value for the ManagedBy resource tag')
param tagManagedBy string

@description('When true, skips resource group and Key Vault creation; subscription Reader is still assigned')
param skipKeyVault bool = false

//******************************************************************
// VARIABLES
//******************************************************************
var resourceTags = {
  Owner: tagOwner
  ManagedBy: tagManagedBy
}

// Built-in role definition IDs (fixed GUIDs, same in every tenant)
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader

//******************************************************************
// RESOURCE GROUP  (skipped when skipKeyVault = true)
//******************************************************************
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = if (!skipKeyVault) {
  name: azResourceGroupName
  location: azResourceGroupLocation
  tags: resourceTags
}

//******************************************************************
// KEY VAULT  (skipped when skipKeyVault = true)
//******************************************************************
module keyVault './bicep/kv.bicep' = if (!skipKeyVault) {
  name: 'deploy-keyvault'
  scope: rg
  params: {
    keyVaultName: azKeyVaultName
    location: azResourceGroupLocation
    tenantId: azTenantId
    resourceTags: resourceTags
    ownerGroupObjectId:      ownerGroupObjectId
    automationGroupObjectId: automationGroupObjectId
  }
}

//******************************************************************
// SUBSCRIPTION-LEVEL ROLE ASSIGNMENT  (always deployed)
// Reader on the subscription — lets the SPN enumerate workspaces,
// capacities, and resource metadata without write access.
//******************************************************************
resource spnSubscriptionReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(azSubscriptionId, spnObjectId, readerRoleId)
  properties: {
    roleDefinitionId: tenantResourceId('Microsoft.Authorization/roleDefinitions', readerRoleId)
    principalId: spnObjectId
    principalType: 'ServicePrincipal'
  }
}
