//******************************************************************
//INPUT PARAMETERS
//******************************************************************
param location string = resourceGroup().location
param keyVaultName string = ''
param tenantId string = 'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
param enableRbacAuthorization bool = true
param accessPolicies object = {
  list: []
}
param resourceTags object = {}

// Optional: when provided, role assignments are created on the KV.
// Pass empty string to skip.
param ownerGroupObjectId      string = ''  // sg-fabcat-owner      → Key Vault Administrator
param automationGroupObjectId string = ''  // sg-fabcat-automation → Key Vault Secrets User

var kvAdministratorRoleId = '00482a5a-887f-4fb3-b363-3b7fe8e74483' // Key Vault Administrator
var kvSecretsUserRoleId   = '4633458b-17de-408a-b874-0445c86b69e6' // Key Vault Secrets User

//******************************************************************
//RESOURCES & MODULES
//******************************************************************
resource keyVault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: keyVaultName
  location: location
  properties: {
    tenantId: tenantId
    sku: {
      family: 'A'
      name: 'standard'
    }
    publicNetworkAccess: 'Enabled'
    enableRbacAuthorization: enableRbacAuthorization
    accessPolicies: (enableRbacAuthorization == true) ? [] : accessPolicies.list
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enablePurgeProtection: true
    // Not needed for secret storage; keep off to reduce attack surface
    enabledForDeployment: false
    enabledForTemplateDeployment: false
    enabledForDiskEncryption: false
  }
  tags: resourceTags
}

//******************************************************************
// ROLE ASSIGNMENTS  (created only when group IDs are supplied)
//******************************************************************
resource kvAdministratorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (ownerGroupObjectId != '') {
  name: guid(keyVault.id, ownerGroupObjectId, kvAdministratorRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvAdministratorRoleId)
    principalId: ownerGroupObjectId
    principalType: 'Group'
  }
}

resource secretsUserAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (automationGroupObjectId != '') {
  name: guid(keyVault.id, automationGroupObjectId, kvSecretsUserRoleId)
  scope: keyVault
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', kvSecretsUserRoleId)
    principalId: automationGroupObjectId
    principalType: 'Group'
  }
}

//******************************************************************
//OUTPUTS
//******************************************************************
output keyVaultId string = keyVault.id
output keyVaultUri string = keyVault.properties.vaultUri