
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

@description('Resource group name')
param azResourceGroupName string

@description('Azure region for all resources')
param azResourceGroupLocation string = 'norwayeast'

@description('Key Vault name (3-24 chars, globally unique)')
param azKeyVaultName string

@description('Object ID of the Service Principal (FabricCatalyst.srvprincipal) — assigned subscription Reader directly')
param spnObjectId string

@description('Object ID of sg-fabcat-owner security group — assigned Key Vault Administrator')
param ownerGroupObjectId string

@description('Object ID of sg-fabcat-automation security group — assigned Key Vault Secrets User')
param automationGroupObjectId string

//******************************************************************
// VARIABLES
//******************************************************************
var resourceTags = {
  Owner: 'svenchio@techtacofriday.com'
  ManagedBy: 'FabricCatalyst-IaC'
}

// Built-in role definition IDs (fixed GUIDs, same in every tenant)
var readerRoleId = 'acdd72a7-3385-48ef-bd42-f606fba81ae7' // Reader

//******************************************************************
// RESOURCE GROUP
//******************************************************************
resource rg 'Microsoft.Resources/resourceGroups@2023-07-01' = {
  name: azResourceGroupName
  location: azResourceGroupLocation
  tags: resourceTags
}

//******************************************************************
// KEY VAULT  (inlined — no external module dependency)
//******************************************************************
module keyVault '../../../templates/bicep/kv.bicep' = {
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
// SUBSCRIPTION-LEVEL ROLE ASSIGNMENT
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

//******************************************************************
// OUTPUTS
//******************************************************************
output keyVaultId  string = keyVault.outputs.keyVaultId
output keyVaultUri string = keyVault.outputs.keyVaultUri
