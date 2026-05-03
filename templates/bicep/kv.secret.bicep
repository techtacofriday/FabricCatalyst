//******************************************************************
//INPUT PARAMETERS
//******************************************************************

//GENERAL
param kvName string = 'fabcat-shared-d-kv-ne'

param kvAssetName string = ''

@secure()
param kvAssetValue string = ''

//******************************************************************
//RESOURCES & MODULES
//******************************************************************
resource keyVault 'Microsoft.KeyVault/vaults@2021-06-01-preview' existing = {
  name: kvName
}

//******************************************************************
resource keyVaultSecret 'Microsoft.KeyVault/vaults/secrets@2021-11-01-preview' =  {
  name: kvAssetName
  parent: keyVault
  properties: {
    attributes: {
      enabled: true
    }
    value: kvAssetValue
  }
}