//******************************************************************
//INPUT PARAMETERS
//******************************************************************
param location string = resourceGroup().location
param serverName string = 'template'
param sqlDBName string = 'sqlDBName'
param maxSizeBytes int = 2147483648
param databaseCollation string = 'SQL_Latin1_General_CP1_CI_AS'
param dbSkuName string = 'Standard'
param dbSkuTier string = 'Standard'
param dbSkuCapacity int = 10

param resourceTags object = {}

//******************************************************************
//RESOURCES & MODULES
//******************************************************************

resource sqlServer 'Microsoft.Sql/servers@2021-11-01' existing = {
  name: serverName
}

resource sqlDatabase 'Microsoft.Sql/servers/databases@2024-05-01-preview' = {
  name: sqlDBName
  parent: sqlServer
  location: location
  tags: resourceTags
  sku: {
    name: dbSkuName
    tier: dbSkuTier
    capacity: dbSkuCapacity
  }
  properties: {
    zoneRedundant: false
    requestedBackupStorageRedundancy: 'Local'
    collation: databaseCollation
    maxSizeBytes: maxSizeBytes
    catalogCollation: 'SQL_Latin1_General_CP1_CI_AS'
  }
}

//******************************************************************
//OUTPUTS
//******************************************************************
output sqlDatabaseId string = sqlDatabase.id